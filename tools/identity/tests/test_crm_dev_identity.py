"""tools/identity/crm_dev_identity.py (AA-935): DRY RUN by default, account guard, lookups by name, SUPPRESS on create,
idempotent re-runs, secrets never printed, the user list in step with the SES receipt rule. No AWS access: fakes."""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

import crm_dev_identity as tool

REPO = Path(__file__).resolve().parents[3]
CLIENT_SECRET = "CLIENT-SECRET-VALUE-do-not-print"


class NotFound(Exception):
    pass


class FakeIdp:
    def __init__(self, existing: dict[str, str] | None = None) -> None:
        self.users = dict(existing or {})  # email -> sub
        self.created: list[dict] = []

    def list_user_pools(self, **kw):
        if "NextToken" not in kw:
            return {"UserPools": [{"Name": "aa-workforce-dev", "Id": "w"}], "NextToken": "p2"}
        return {"UserPools": [{"Name": "aa-external-dev", "Id": "pool-ext"}]}

    def list_user_pool_clients(self, **kw):
        return {"UserPoolClients": [{"ClientName": "aa-external-dev-cis-portal", "ClientId": "cid"}]}

    def describe_user_pool_client(self, **kw):
        assert kw == {"UserPoolId": "pool-ext", "ClientId": "cid"}
        return {"UserPoolClient": {"ClientSecret": CLIENT_SECRET}}

    def list_users(self, UserPoolId, Filter, Limit):  # noqa: N803 — boto3 names
        email = re.match(r'email = "(.+)"', Filter).group(1)
        sub = self.users.get(email)
        return {"Users": [{"Attributes": [{"Name": "sub", "Value": sub}]}] if sub else []}

    def admin_create_user(self, **kw):
        self.created.append(kw)
        sub = f"sub-{len(self.users) + 1}"
        self.users[kw["Username"]] = sub
        return {"User": {"Attributes": [{"Name": "sub", "Value": sub}]}}


class FakeSm:
    class exceptions:  # noqa: N801 — boto3 shape
        ResourceNotFoundException = NotFound

    def __init__(self, values: dict[str, str] | None = None) -> None:
        self.values = dict(values or {})
        self.writes: list[tuple[str, str]] = []

    def describe_secret(self, SecretId):  # noqa: N803
        if SecretId not in self.values:
            raise NotFound(SecretId)
        return {"Name": SecretId}

    def get_secret_value(self, SecretId):  # noqa: N803
        if SecretId not in self.values or self.values[SecretId] is None:
            raise NotFound(SecretId)
        return {"SecretString": self.values[SecretId]}

    def put_secret_value(self, SecretId, SecretString):  # noqa: N803
        self.values[SecretId] = SecretString
        self.writes.append((SecretId, SecretString))
        return {"VersionId": "v1"}

    def create_secret(self, Name, Description, SecretString, Tags):  # noqa: N803
        self.values[Name] = SecretString
        self.writes.append((Name, SecretString))
        return {"VersionId": "v0"}


class FakeSts:
    def __init__(self, account: str = tool.DEFAULT_ACCOUNT) -> None:
        self.account = account

    def get_caller_identity(self):
        return {"Account": self.account}


def run(argv, idp=None, sm=None, sts=None):
    return tool.main(["--profile", "", *argv], (sts or FakeSts(), idp or FakeIdp(), sm or FakeSm()))


def lines(capsys) -> list[dict]:
    return [json.loads(x) for x in capsys.readouterr().out.splitlines()]


def test_user_list_matches_the_seeder_catalogue_and_the_receipt_rule():
    users = tool.load_users()
    assert {(u.agency, u.role) for u in users} >= {("sen-vang", "owner"), ("southern-cross", "owner")}
    assert all(u.role in tool.ROLES for u in users)
    mailbox = (REPO / "accounts" / "aa365" / "e2e_mailbox.tf").read_text(encoding="utf-8")
    assert "tools/identity/crm_e2e_users.json" in mailbox
    assert 'e2e-test-crm-${u.agency}-${u.role}@${local.e2e_mail_domain}' in mailbox
    assert users[0].email("example.test") == "e2e-test-crm-sen-vang-owner@e2e-mail.example.test"


def test_dry_run_writes_nothing(capsys):
    idp, sm = FakeIdp(), FakeSm()
    assert run(["e2e-users", "--write-secrets"], idp, sm) == 0
    rows = lines(capsys)
    assert {r.get("action") for r in rows[:-1]} == {"would_create"}
    assert rows[-1]["summary"] == "dry_run" and rows[-1]["created"] == 0
    assert idp.created == [] and sm.writes == []


def test_apply_creates_with_suppress_then_is_idempotent(capsys):
    idp, sm = FakeIdp(), FakeSm()
    assert run(["e2e-users", "--apply", "--write-secrets"], idp, sm) == 0
    rows = lines(capsys)
    assert all(c["MessageAction"] == "SUPPRESS" for c in idp.created)
    assert all("TemporaryPassword" not in c for c in idp.created)
    assert {a["Name"]: a["Value"] for a in idp.created[0]["UserAttributes"]}["email_verified"] == "true"
    assert rows[0]["member"] == f"sen-vang:owner:{rows[0]['sub']}"
    assert rows[-1]["seeder"].startswith("python -m app.seed --apply --member sen-vang:owner:")
    stored = json.loads(sm.values["crm/dev/e2e-test-crm/sen-vang-owner"])
    assert stored == {"email": rows[0]["email"], "sub": rows[0]["sub"], "agency": "sen-vang", "role": "owner", "pool": "external"}
    assert "password" not in json.dumps(stored)
    created = len(idp.created)
    assert run(["e2e-users", "--apply"], idp, sm) == 0
    again = lines(capsys)
    assert {r["action"] for r in again[:-1]} == {"exists"} and len(idp.created) == created


def test_account_guard_refuses_another_account(capsys):
    assert run(["e2e-users"], sts=FakeSts("111111111111")) == 1
    assert "refused" in capsys.readouterr().err


def test_web_secret_keeps_the_session_secret_and_never_prints_values(capsys):
    sm = FakeSm({"crm/dev/web": None})
    assert run(["web-secret"], sm=sm) == 0
    first = lines(capsys)[0]
    assert first["action"] == "would_write" and set(first["changed"]) == {"session_secret", "cognito_client_secret"}
    assert sm.writes == []
    assert run(["web-secret", "--apply"], sm=sm) == 0
    out = capsys.readouterr().out
    assert CLIENT_SECRET not in out
    value = json.loads(sm.values["crm/dev/web"])
    assert value["cognito_client_secret"] == CLIENT_SECRET and len(value["session_secret"]) >= 32
    assert value["session_secret"] not in out
    assert run(["web-secret", "--apply"], sm=sm) == 0
    assert lines(capsys)[0]["action"] == "unchanged"
    kept = value["session_secret"]
    assert run(["web-secret", "--apply", "--rotate-session"], sm=sm) == 0
    capsys.readouterr()
    assert json.loads(sm.values["crm/dev/web"])["session_secret"] != kept


def test_web_secret_needs_the_terraform_shell(capsys):
    assert run(["web-secret", "--apply"], sm=FakeSm()) == 1
    assert "crm_web.tf" in capsys.readouterr().err


def test_bad_user_file_is_refused(tmp_path):
    bad = tmp_path / "u.json"
    bad.write_text(json.dumps({"users": [{"agency": "x", "role": "admin"}]}))
    with pytest.raises(tool.ToolError):
        tool.load_users(bad)
    dup = tmp_path / "d.json"
    dup.write_text(json.dumps({"users": [{"agency": "x", "role": "owner"}, {"agency": "x", "role": "owner"}]}))
    with pytest.raises(tool.ToolError):
        tool.load_users(dup)
