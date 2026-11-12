"""Offline tests of tools/identity/tripplanner_assertion_key.py (AA-1092): fakes for STS and Secrets Manager, no AWS.

Run from the repo root: python3 -m pytest -q tools/identity/tests/test_tripplanner_assertion_key.py
"""
from __future__ import annotations

import json

import pytest

import tripplanner_assertion_key as tool

NAME = "tripplanner/dev/tenant-assertion-key"
NOW = 1762400000
# Invented values only; built at run time so no literal looks like a key.
OLD = "-".join(["fake", "old", "assertion", "key", "material", "0123456789"])
NEW = "-".join(["fake", "new", "assertion", "key", "material", "9876543210"])


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


def _write(sm, **kw):
    kw.setdefault("rotate", False)
    kw.setdefault("grace_hours", 24)
    kw.setdefault("apply", True)
    return tool.write_secret(sm, "dev", now=NOW, make_key=lambda: NEW, **kw)


def test_first_fill_writes_current_and_the_cut_over_window():
    sm = FakeSm({NAME: None})
    got = _write(sm)
    assert got["action"] == "written" and got["mode"] == "first_fill"
    assert sm.puts == [(NAME, {"current": NEW, "edge_derived_until": NOW + 24 * 3600})]
    assert got["fields"] == ["current", "edge_derived_until"]


@pytest.mark.parametrize("raw", ["REPLACE_ME", "", json.dumps({"current": "REPLACE_ME"})])
def test_first_fill_over_a_placeholder(raw):
    sm = FakeSm({NAME: raw})
    _write(sm)
    assert sm.puts[0][1]["current"] == NEW


def test_dry_run_writes_nothing():
    sm = FakeSm({NAME: None})
    got = _write(sm, apply=False)
    assert got["action"] == "would_write" and sm.puts == []


def test_first_fill_refuses_an_existing_key():
    sm = FakeSm({NAME: json.dumps({"current": OLD})})
    with pytest.raises(tool.ToolError, match="--rotate"):
        _write(sm)
    assert sm.puts == []


def test_rotate_keeps_the_old_key_as_previous_for_the_grace():
    sm = FakeSm({NAME: json.dumps({"current": OLD})})
    got = _write(sm, rotate=True, grace_hours=6)
    assert sm.puts == [(NAME, {"current": NEW, "previous": OLD, "previous_until": NOW + 6 * 3600})]
    assert got["grace_until"] == NOW + 6 * 3600


def test_rotate_inside_the_cut_over_keeps_the_edge_window_and_drops_an_expired_one():
    sm = FakeSm({NAME: json.dumps({"current": OLD, "edge_derived_until": NOW + 60})})
    _write(sm, rotate=True)
    assert sm.puts[0][1]["edge_derived_until"] == NOW + 60
    sm = FakeSm({NAME: json.dumps({"current": OLD, "edge_derived_until": NOW - 60})})
    _write(sm, rotate=True)
    assert "edge_derived_until" not in sm.puts[0][1]


def test_rotate_refuses_an_empty_secret():
    with pytest.raises(tool.ToolError, match="first fill"):
        _write(FakeSm({NAME: None}), rotate=True)


@pytest.mark.parametrize("hours", [0, tool.MAX_GRACE_HOURS + 1])
def test_a_grace_outside_the_bounds_is_refused(hours):
    with pytest.raises(tool.ToolError, match="grace"):
        _write(FakeSm({NAME: None}), grace_hours=hours)


@pytest.mark.parametrize("raw", ["not json", json.dumps({"current": OLD, "surprise": 1}), json.dumps([1])])
def test_a_value_it_does_not_understand_is_never_overwritten(raw):
    sm = FakeSm({NAME: raw})
    with pytest.raises(tool.ToolError, match="by hand"):
        _write(sm, rotate=True)
    assert sm.puts == []


def test_missing_shell_is_refused():
    with pytest.raises(tool.ToolError, match="apply"):
        _write(FakeSm({}))


def test_main_prints_no_key_and_guards_the_account(capsys):
    sm = FakeSm({NAME: None})
    assert tool.main(["--apply"], clients=(FakeSts(), sm)) == 0
    out = capsys.readouterr().out
    written = sm.puts[0][1]["current"]
    assert written not in out and len(written) >= tool.MIN_KEY_LENGTH
    assert json.loads(out)["action"] == "written"

    sm = FakeSm({NAME: None})
    assert tool.main(["--apply"], clients=(FakeSts("111111111111"), sm)) == 1
    assert "refused" in capsys.readouterr().err and sm.puts == []
