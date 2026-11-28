"""Offline tests of tools/identity/client_secret_rotate.py (AA-1182, lesson S296): fakes for STS, Cognito and Secrets
Manager, plus one botocore Stubber run that checks the Cognito calls against the service model. No AWS.

Run from the repo root: python3 -m pytest -q tools/identity/tests/test_client_secret_rotate.py
"""
from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone

import pytest
from botocore.stub import Stubber
from conftest import make_client

import client_secret_rotate as tool

T0 = datetime(2026, 11, 20, 8, 0, tzinfo=timezone.utc)
# Invented values only, built at run time so no literal looks like a key.
OLD_VALUE = "-".join(["old", "client", "value", "kept", "in", "memory"])
NEW_VALUE = "-".join(["fresh", "client", "value", "from", "add", "response"])


class FakeSts:
    def __init__(self, account: str = tool.DEFAULT_ACCOUNT) -> None:
        self.account = account

    def get_caller_identity(self):
        return {"Account": self.account}


class FakeIdp:
    """Pools and clients by name; secrets per client id: [(id, created)]. Describe never returns a value (the
    behaviour after a rotation), so a tool that still reads it would fail these tests."""

    def __init__(self, secrets: dict[str, list[tuple[str, datetime]]] | None = None, new_value: str = NEW_VALUE):
        self.pools = {"aa-workforce-dev": "pool-wf", "aa-partner-dev": "pool-pa", "aa-m2m-dev": "pool-m2m"}
        self.clients = {c.client.format(env="dev"): (c.pool.format(env="dev"), f"id-{n}")
                        for n, c in tool.CLIENTS.items()}
        self.secrets = {cid: list(v) for cid, v in (secrets or {}).items()}
        self.new_value = new_value
        self.added: list[str] = []
        self.deleted: list[str] = []

    def list_user_pools(self, **kw):
        return {"UserPools": [{"Name": n, "Id": i} for n, i in self.pools.items()]}

    def list_user_pool_clients(self, **kw):
        return {"UserPoolClients": [{"ClientName": n, "ClientId": cid} for n, (pool, cid) in self.clients.items()
                                    if self.pools[pool] == kw["UserPoolId"]]}

    def list_user_pool_client_secrets(self, **kw):
        return {"ClientSecrets": [{"ClientSecretId": i, "ClientSecretCreateDate": d}
                                  for i, d in self.secrets.get(kw["ClientId"], [])]}

    def add_user_pool_client_secret(self, **kw):
        new_id = f"sec-new-{len(self.added) + 1}"
        self.added.append(new_id)
        self.secrets.setdefault(kw["ClientId"], []).append((new_id, T0 + timedelta(days=1)))
        return {"ClientSecretDescriptor": {"ClientSecretId": new_id, "ClientSecretValue": self.new_value,
                                           "ClientSecretCreateDate": T0 + timedelta(days=1)}}

    def delete_user_pool_client_secret(self, **kw):
        self.deleted.append(kw["ClientSecretId"])
        self.secrets[kw["ClientId"]] = [s for s in self.secrets[kw["ClientId"]] if s[0] != kw["ClientSecretId"]]
        return {}

    def describe_user_pool_client(self, **kw):  # pragma: no cover — must never be called
        raise AssertionError("the rotation tool must not read the secret back with DescribeUserPoolClient")


class _NotFound(Exception):
    pass


class FakeSm:
    class exceptions:  # noqa: N801 — boto3 shape
        ResourceNotFoundException = _NotFound

    def __init__(self, values: dict[str, str | None], changed: datetime = T0, corrupt_reads: int = 0,
                 fail_puts: int = 0) -> None:
        self.values = dict(values)
        self.changed = {k: changed for k in values}
        self.puts: list[tuple[str, dict]] = []
        self.corrupt_reads = corrupt_reads  # reads after a put that return a stale value (hash check must catch it)
        self.fail_puts = fail_puts

    def describe_secret(self, SecretId):  # noqa: N803 — boto3 names
        if SecretId not in self.values:
            raise _NotFound(SecretId)
        return {"Name": SecretId, "LastChangedDate": self.changed[SecretId]}

    def get_secret_value(self, SecretId):  # noqa: N803
        if self.values.get(SecretId) is None:
            raise _NotFound(SecretId)
        if self.puts and self.corrupt_reads:
            self.corrupt_reads -= 1
            return {"SecretString": json.dumps({**json.loads(self.values[SecretId]), "client_secret": "stale"})}
        return {"SecretString": self.values[SecretId]}

    def put_secret_value(self, SecretId, SecretString):  # noqa: N803
        if self.fail_puts:
            self.fail_puts -= 1
            raise RuntimeError("simulated write failure")
        self.values[SecretId] = SecretString
        self.changed[SecretId] = T0 + timedelta(days=2)
        self.puts.append((SecretId, json.loads(SecretString)))
        return {"VersionId": f"v{len(self.puts)}"}


M2M_SECRET = "aa-crm/dev/m2m-booking-client"
M2M_BODY = json.dumps({"client_id": "m2m-client", "client_secret": OLD_VALUE, "token_url": "https://auth.invalid",
                       "scopes": "a/b"})


def _run(argv, idp, sm, capsys, sts=None):
    rc = tool.main(["--profile", "", *argv], clients=(sts or FakeSts(), idp, sm))
    captured = capsys.readouterr()
    for value in (OLD_VALUE, NEW_VALUE):
        assert value not in captured.out and value not in captured.err  # never printed, whatever happens
    return rc, [json.loads(line) for line in captured.out.splitlines()], captured.err


def test_registry_covers_the_seven_clients_rotated_in_s296():
    assert set(tool.CLIENTS) == {"crm-m2m", "partner-web", "cis-admin", "breakglass", "booking-staff", "crm-staff",
                                 "academy-web"}
    keys = {(c.secret, c.key) for c in tool.CLIENTS.values()}
    assert len(keys) == len(tool.CLIENTS)  # one key per client, never shared
    assert tool.stored_location("aa-workforce-dev-breakglass", "dev") == ("aa-cis/dev/admin-web",
                                                                         "breakglass_client_secret")
    assert tool.stored_location("aa-workforce-dev-unknown", "dev") is None


def test_dry_run_adds_nothing(capsys):
    idp = FakeIdp({"id-crm-m2m": [("sec-old", T0)]})
    sm = FakeSm({M2M_SECRET: M2M_BODY})
    rc, lines, _ = _run(["add", "--client", "crm-m2m"], idp, sm, capsys)
    assert rc == 0
    assert lines == [{"client": "crm-m2m", "app_client": "aa-m2m-dev-crm", "secret": M2M_SECRET,
                      "key": "client_secret", "secrets_before": 1, "action": "would_add"}]
    assert idp.added == [] and sm.puts == []


def test_add_stores_the_value_from_the_add_response_and_keeps_other_keys(capsys):
    idp = FakeIdp({"id-crm-m2m": [("sec-old", T0)]})
    sm = FakeSm({M2M_SECRET: M2M_BODY})
    rc, lines, _ = _run(["add", "--client", "crm-m2m", "--apply"], idp, sm, capsys)
    assert rc == 0
    assert idp.added == ["sec-new-1"] and idp.deleted == []
    assert sm.puts == [(M2M_SECRET, {**json.loads(M2M_BODY), "client_secret": NEW_VALUE})]
    row = lines[0]
    assert (row["action"], row["new_secret_id"], row["stored"], row["secrets_after"]) == \
        ("added", "sec-new-1", "hash-verified", 2)
    assert row["next"][0].startswith("aws ecs update-service --cluster aa-cis-dev-cluster --service aa-crm-dev-api ")
    assert "\\" not in row["next"][0] and "\n" not in row["next"][0]  # single-line command (WSL rule)
    assert row["next"][-1].endswith("retire --client crm-m2m --keep sec-new-1 --apply")


def test_add_into_an_empty_shell(capsys):
    idp = FakeIdp({"id-cis-admin": [("sec-old", T0)]})
    sm = FakeSm({"aa-cis/dev/admin-web": None})
    rc, _, _ = _run(["add", "--client", "cis-admin", "--apply"], idp, sm, capsys)
    assert rc == 0
    assert sm.puts == [("aa-cis/dev/admin-web", {"cis_admin_client_secret": NEW_VALUE})]


def test_add_is_refused_at_two_secrets_and_for_a_missing_shell(capsys):
    idp = FakeIdp({"id-crm-m2m": [("sec-a", T0), ("sec-b", T0 + timedelta(hours=1))]})
    rc, _, err = _run(["add", "--client", "crm-m2m", "--apply"], idp, FakeSm({M2M_SECRET: M2M_BODY}), capsys)
    assert rc == 1 and "already has 2 secrets" in err and idp.added == []

    idp = FakeIdp({"id-crm-m2m": [("sec-a", T0)]})
    rc, _, err = _run(["add", "--client", "crm-m2m", "--apply"], idp, FakeSm({}), capsys)
    assert rc == 1 and "does not exist" in err and idp.added == []


def test_add_refuses_a_non_json_secret_before_touching_cognito(capsys):
    idp = FakeIdp({"id-crm-m2m": [("sec-a", T0)]})
    rc, _, err = _run(["add", "--client", "crm-m2m", "--apply"], idp, FakeSm({M2M_SECRET: "plain-text"}), capsys)
    assert rc == 1 and "JSON object" in err and idp.added == []


def test_a_failed_hash_check_is_retried_once(capsys):
    idp = FakeIdp({"id-crm-m2m": [("sec-old", T0)]})
    sm = FakeSm({M2M_SECRET: M2M_BODY}, corrupt_reads=1)
    rc, lines, _ = _run(["add", "--client", "crm-m2m", "--apply"], idp, sm, capsys)
    assert rc == 0 and lines[0]["stored"] == "hash-verified" and len(sm.puts) == 2
    assert idp.deleted == []


def test_store_failure_deletes_the_new_secret_again(capsys):
    idp = FakeIdp({"id-crm-m2m": [("sec-old", T0)]})
    sm = FakeSm({M2M_SECRET: M2M_BODY}, fail_puts=2)
    rc, lines, err = _run(["add", "--client", "crm-m2m", "--apply"], idp, sm, capsys)
    assert rc == 1 and lines == []
    assert idp.deleted == ["sec-new-1"]
    assert [s[0] for s in idp.secrets["id-crm-m2m"]] == ["sec-old"]
    assert "storing the new value failed (RuntimeError)" in err and "deleted again" in err
    assert json.loads(sm.values[M2M_SECRET])["client_secret"] == OLD_VALUE


def test_retire_deletes_the_old_secret_after_the_stored_write(capsys):
    idp = FakeIdp({"id-crm-m2m": [("sec-old", T0), ("sec-new", T0 + timedelta(days=1))]})
    sm = FakeSm({M2M_SECRET: M2M_BODY}, changed=T0 + timedelta(days=1, minutes=1))
    rc, lines, _ = _run(["retire", "--client", "crm-m2m", "--keep", "sec-new"], idp, sm, capsys)
    assert rc == 0 and lines[0]["action"] == "would_delete" and lines[0]["retire"] == ["sec-old"]
    assert idp.deleted == []
    rc, lines, _ = _run(["retire", "--client", "crm-m2m", "--keep", "sec-new", "--apply"], idp, sm, capsys)
    assert rc == 0 and idp.deleted == ["sec-old"] and lines[0]["secrets_after"] == 1


@pytest.mark.parametrize(("keep", "changed_offset", "message"), [
    ("sec-old", timedelta(days=2), "is not the newest secret"),
    ("sec-new", timedelta(hours=1), "has not changed since"),
    ("sec-none", timedelta(days=2), "has no secret"),
])
def test_retire_refusals(capsys, keep, changed_offset, message):
    idp = FakeIdp({"id-crm-m2m": [("sec-old", T0), ("sec-new", T0 + timedelta(days=1))]})
    sm = FakeSm({M2M_SECRET: M2M_BODY}, changed=T0 + changed_offset)
    rc, _, err = _run(["retire", "--client", "crm-m2m", "--keep", keep, "--apply"], idp, sm, capsys)
    assert rc == 1 and message in err and idp.deleted == []


def test_retire_refuses_a_single_secret(capsys):
    idp = FakeIdp({"id-crm-m2m": [("sec-new", T0)]})
    rc, _, err = _run(["retire", "--client", "crm-m2m", "--keep", "sec-new", "--apply"], idp,
                      FakeSm({M2M_SECRET: M2M_BODY}), capsys)
    assert rc == 1 and "nothing to retire" in err


def test_status_reports_ids_and_presence_only(capsys):
    idp = FakeIdp({"id-crm-m2m": [("sec-old", T0)]})
    rc, lines, _ = _run(["status", "--client", "crm-m2m"], idp, FakeSm({M2M_SECRET: M2M_BODY}), capsys)
    assert rc == 0
    assert lines[0]["cognito_secrets"][0]["id"] == "sec-old" and lines[0]["key_set"] is True
    rc, lines, _ = _run(["status"], FakeIdp(), FakeSm({}), capsys)
    assert rc == 0 and len(lines) == len(tool.CLIENTS) and all(not row["key_set"] for row in lines)


def test_wrong_account_is_refused(capsys):
    idp = FakeIdp({"id-crm-m2m": [("sec-old", T0)]})
    rc, _, err = _run(["add", "--client", "crm-m2m", "--apply"], idp, FakeSm({M2M_SECRET: M2M_BODY}), capsys,
                      sts=FakeSts("111111111111"))
    assert rc == 1 and "refused" in err and idp.added == []


def test_cognito_calls_match_the_service_model(capsys):
    """The real botocore model validates every parameter and response shape of the three rotation calls."""
    idp = make_client("cognito-idp")
    stub = Stubber(idp)
    pools = {"UserPools": [{"Name": "aa-m2m-dev", "Id": "us-west-1_TESTPOOL"}]}
    clients = {"UserPoolClients": [{"ClientName": "aa-m2m-dev-crm", "ClientId": "m2mclientid000000000000000"}]}
    ids = {"UserPoolId": "us-west-1_TESTPOOL", "ClientId": "m2mclientid000000000000000"}
    stub.add_response("list_user_pools", pools, {"MaxResults": 60})
    stub.add_response("list_user_pool_clients", clients, {"UserPoolId": "us-west-1_TESTPOOL", "MaxResults": 60})
    stub.add_response("list_user_pool_client_secrets",
                      {"ClientSecrets": [{"ClientSecretId": "us-west-1_TESTPOOL--old", "ClientSecretCreateDate": T0}]},
                      ids)
    stub.add_response("add_user_pool_client_secret",
                      {"ClientSecretDescriptor": {"ClientSecretId": "us-west-1_TESTPOOL--new",
                                                  "ClientSecretValue": NEW_VALUE,
                                                  "ClientSecretCreateDate": T0 + timedelta(days=1)}}, ids)
    stub.activate()
    sm = FakeSm({M2M_SECRET: M2M_BODY})
    rc, lines, _ = _run(["add", "--client", "crm-m2m", "--apply"], idp, sm, capsys)
    stub.assert_no_pending_responses()
    assert rc == 0 and lines[0]["new_secret_id"] == "us-west-1_TESTPOOL--new"
    assert sm.puts[0][1]["client_secret"] == NEW_VALUE
    stub.deactivate()

    stub2 = Stubber(idp)
    stub2.add_response("list_user_pools", pools, {"MaxResults": 60})
    stub2.add_response("list_user_pool_clients", clients, {"UserPoolId": "us-west-1_TESTPOOL", "MaxResults": 60})
    listing = {"ClientSecrets": [{"ClientSecretId": "us-west-1_TESTPOOL--old", "ClientSecretCreateDate": T0},
                                 {"ClientSecretId": "us-west-1_TESTPOOL--new",
                                  "ClientSecretCreateDate": T0 + timedelta(days=1)}]}
    stub2.add_response("list_user_pool_client_secrets", listing, ids)
    stub2.add_response("delete_user_pool_client_secret", {}, {**ids, "ClientSecretId": "us-west-1_TESTPOOL--old"})
    stub2.add_response("list_user_pool_client_secrets", {"ClientSecrets": listing["ClientSecrets"][1:]}, ids)
    stub2.activate()
    rc, lines, _ = _run(["retire", "--client", "crm-m2m", "--keep", "us-west-1_TESTPOOL--new", "--apply"], idp, sm,
                        capsys)
    stub2.assert_no_pending_responses()
    stub2.deactivate()
    assert rc == 0 and lines[0]["secrets_after"] == 1
