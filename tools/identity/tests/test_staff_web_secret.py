"""Offline tests of tools/identity/staff_web_secret.py (AA-911): fakes for STS, Cognito and Secrets Manager, no AWS.

Run from the repo root: python3 -m pytest -q tools/identity/tests/test_staff_web_secret.py
"""
from __future__ import annotations

import json

import staff_web_secret as tool

# Invented values only (never real client secrets); built at run time so no literal looks like a key.
CLIENT_SECRETS = {
    "aa-workforce-dev-cis-admin": "-".join(["fake", "cis", "admin", "value"]),
    "aa-workforce-dev-breakglass": "-".join(["fake", "break", "glass", "value"]),
    "aa-workforce-dev-booking-staff": "-".join(["fake", "booking", "staff", "value"]),
}


class FakeSts:
    def __init__(self, account: str = tool.DEFAULT_ACCOUNT) -> None:
        self.account = account

    def get_caller_identity(self):
        return {"Account": self.account}


class FakeIdp:
    def __init__(self, secrets: dict[str, str] | None = None) -> None:
        self.secrets = dict(CLIENT_SECRETS if secrets is None else secrets)

    def list_user_pools(self, **kw):
        return {"UserPools": [{"Name": "aa-external-dev", "Id": "pool-ext"}, {"Name": "aa-workforce-dev", "Id": "pool-wf"}]}

    def list_user_pool_clients(self, **kw):
        assert kw["UserPoolId"] == "pool-wf"
        return {"UserPoolClients": [{"ClientName": n, "ClientId": f"id-{n}"} for n in self.secrets]}

    def describe_user_pool_client(self, **kw):
        name = kw["ClientId"].removeprefix("id-")
        return {"UserPoolClient": {"ClientName": name, "ClientSecret": self.secrets[name]}}


class _NotFound(Exception):
    pass


class FakeSm:
    class exceptions:  # noqa: N801 — boto3 shape
        ResourceNotFoundException = _NotFound

    def __init__(self, shells: dict[str, str | None]) -> None:
        self.values = dict(shells)  # name -> SecretString or None (shell without a version)
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


SHELLS = {"aa-cis/dev/admin-web": None, "booking/dev/admin-web": None}


def _run(argv, sm, idp=None, sts=None, capsys=None):
    rc = tool.main(argv, clients=(sts or FakeSts(), idp or FakeIdp(), sm))
    lines = [json.loads(line) for line in capsys.readouterr().out.splitlines()] if capsys else []
    return rc, lines


def test_dry_run_writes_nothing_and_names_the_keys(capsys):
    sm = FakeSm(SHELLS)
    rc, lines = _run([], sm, capsys=capsys)
    assert rc == 0
    assert sm.puts == []
    assert [(line["secret"], line["action"], line["changed"]) for line in lines] == [
        ("aa-cis/dev/admin-web", "would_write", ["breakglass_client_secret", "cis_admin_client_secret"]),
        ("booking/dev/admin-web", "would_write", ["booking_staff_client_secret"]),
    ]


def test_apply_writes_each_shell_from_its_clients(capsys):
    sm = FakeSm(SHELLS)
    rc, lines = _run(["--apply"], sm, capsys=capsys)
    assert rc == 0
    assert dict(sm.puts) == {
        "aa-cis/dev/admin-web": {
            "cis_admin_client_secret": CLIENT_SECRETS["aa-workforce-dev-cis-admin"],
            "breakglass_client_secret": CLIENT_SECRETS["aa-workforce-dev-breakglass"],
        },
        "booking/dev/admin-web": {"booking_staff_client_secret": CLIENT_SECRETS["aa-workforce-dev-booking-staff"]},
    }
    assert {line["action"] for line in lines} == {"written"}


def test_output_never_contains_a_secret_value(capsys):
    sm = FakeSm(SHELLS)
    tool.main(["--apply"], clients=(FakeSts(), FakeIdp(), sm))
    captured = capsys.readouterr()
    for value in CLIENT_SECRETS.values():
        assert value not in captured.out
        assert value not in captured.err


def test_rerun_is_a_no_op_and_other_keys_are_kept(capsys):
    current = {
        "cis_admin_client_secret": CLIENT_SECRETS["aa-workforce-dev-cis-admin"],
        "breakglass_client_secret": CLIENT_SECRETS["aa-workforce-dev-breakglass"],
        "kept_key": "kept",
    }
    sm = FakeSm({"aa-cis/dev/admin-web": json.dumps(current), "booking/dev/admin-web": None})
    rc, lines = _run(["--apply"], sm, capsys=capsys)
    assert rc == 0
    assert lines[0]["action"] == "unchanged"
    assert [name for name, _ in sm.puts] == ["booking/dev/admin-web"]

    rotated = FakeIdp({**CLIENT_SECRETS, "aa-workforce-dev-cis-admin": "-".join(["new", "cis", "value"])})
    sm2 = FakeSm({"aa-cis/dev/admin-web": json.dumps(current), "booking/dev/admin-web": None})
    _run(["--apply", "--only", "cis"], sm2, idp=rotated, capsys=capsys)
    assert sm2.puts == [("aa-cis/dev/admin-web", {**current, "cis_admin_client_secret": "new-cis-value"})]


def test_missing_shell_and_wrong_account_are_refused(capsys):
    rc, _ = _run(["--apply"], FakeSm({"booking/dev/admin-web": None}))
    assert rc == 1
    assert "does not exist" in capsys.readouterr().err

    sm = FakeSm(SHELLS)
    rc = tool.main(["--apply"], clients=(FakeSts("111111111111"), FakeIdp(), sm))
    assert rc == 1
    assert sm.puts == []
    assert "refused" in capsys.readouterr().err


def test_public_client_is_refused(capsys):
    idp = FakeIdp({**CLIENT_SECRETS, "aa-workforce-dev-booking-staff": ""})
    rc, _ = _run(["--apply", "--only", "booking"], FakeSm(SHELLS), idp=idp)
    assert rc == 1
    assert "confidential client" in capsys.readouterr().err
