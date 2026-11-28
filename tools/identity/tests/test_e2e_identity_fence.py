"""Tests for tools/identity/e2e_identity_fence.py (AA-1054): the pilot-day listing and disable of the Dev-only E2E
WORKFORCE users. botocore Stubber, no AWS. Invented local parts only for users outside the trigger's list."""

from __future__ import annotations

import json

import pytest

import e2e_identity_fence as ef
from conftest import POOL, make_client
from botocore.stub import Stubber
from workforce_bootstrap import Output

DOMAIN = ef.E2E_MAIL_DOMAIN
ADDRESSES = ef.known_addresses()


class Capture:
    def __init__(self) -> None:
        self.lines: list[str] = []

    def __call__(self, s: str) -> None:
        self.lines.append(s)

    def text(self) -> str:
        return "\n".join(self.lines)


@pytest.fixture
def out():
    cap = Capture()
    return Output(out=cap, err=cap), cap


@pytest.fixture
def idp():
    client = make_client("cognito-idp")
    stub = Stubber(client)
    stub.activate()
    yield client, stub
    stub.deactivate()


def _user(email: str, enabled: bool = True, username: str | None = None, status: str = "CONFIRMED") -> dict:
    return {"Username": username or f"uuid-{abs(hash(email)) % 10**8:08d}-zz", "Enabled": enabled,
            "UserStatus": status, "Attributes": [{"Name": "email", "Value": email}]}


def _list(stub, users: list[dict], token: str | None = None, next_token: str | None = None) -> None:
    params = {"UserPoolId": POOL, "Filter": ef.LIST_FILTER, "AttributesToGet": ["email"]}
    if token:
        params["PaginationToken"] = token
    resp: dict = {"Users": users}
    if next_token:
        resp["PaginationToken"] = next_token
    stub.add_response("list_users", resp, params)


# ── the address map ──────────────────────────────────────────────────────────────────────────────

def test_every_trigger_e2e_constant_has_a_code():
    assert len(ADDRESSES) >= 12
    assert set(ADDRESSES) == set(ef.CODES), "map every E2E_*_EMAIL constant of workforce.py in CODES"
    assert all(ef.is_e2e_address(a) for a in ADDRESSES.values())


def test_codes_are_the_adr_0006a_codes():
    assert set(ef.CODES.values()) == {"A10", "A10a", "A10b", "A10c", "A10d", "A10e", "A10e-2", "A10f", "A10g", "A10h"}
    assert sum(1 for c in ef.CODES.values() if c == "A10e") == 3


def test_an_unmapped_constant_stops_the_tool_before_any_aws_call(idp, out, monkeypatch):
    client, stub = idp
    o, cap = out
    extra = {**ADDRESSES, "E2E_NEW_THING_TEST_STAFF_EMAIL": f"zz-new@{DOMAIN}"}
    with pytest.raises(ef.UnmappedConstant):
        ef.expected_rows(extra)
    monkeypatch.setattr(ef, "known_addresses", lambda: extra)
    assert ef.main(["--pool-id", POOL], out=o, idp=client) == 2      # the Stubber has no response: no call was made
    assert "E2E_NEW_THING_TEST_STAFF_EMAIL" in cap.text()


@pytest.mark.parametrize("email,e2e", [
    (f"e2e@{DOMAIN}", True), (f"  E2E-Owner@{DOMAIN.upper()} ", True), (f"zz@{DOMAIN}", True),
    ("e2e@adventure.asia", False), (f"e2e@x.{DOMAIN}", False), (f"e2e@{DOMAIN}.evil", False), (f"@{DOMAIN}", False),
    ("", False), (None, False),
])
def test_is_e2e_address(email, e2e):
    assert ef.is_e2e_address(email) is e2e


def test_mask_never_shows_the_address():
    for email in ADDRESSES.values():
        label = ef.mask(email)
        assert "@" not in label and DOMAIN not in label and label != email.split("@")[0]


# ── DRY RUN ──────────────────────────────────────────────────────────────────────────────────────

def test_dry_run_lists_codes_and_state_and_changes_nothing(idp, out):
    client, stub = idp
    o, cap = out
    owner = ADDRESSES["E2E_OWNER_TEST_STAFF_EMAIL"]
    admin = ADDRESSES["E2E_CIS_ADMIN_TEST_STAFF_EMAIL"]
    _list(stub, [_user(owner), _user(admin, enabled=False)], next_token="page-2-token-zz")
    _list(stub, [_user(f"zz-stray@{DOMAIN}"), _user("someone@adventure.asia")], token="page-2-token-zz")
    assert ef.run(client, POOL, o, apply=False, as_json=False, addresses=ADDRESSES) == 0
    stub.assert_no_pending_responses()
    text = cap.text()
    assert "DRY RUN" in text and "A10h" in text and "unmapped" in text
    assert "@" not in text and DOMAIN not in text and "uuid-" not in text   # no address, no username
    assert "13 E2E identities known or found, 3 in the pool, 2 enabled" in text


def test_dry_run_json(idp, out):
    client, stub = idp
    o, cap = out
    _list(stub, [_user(ADDRESSES["E2E_TEST_STAFF_EMAIL"])])
    assert ef.run(client, POOL, o, apply=False, as_json=True, addresses=ADDRESSES) == 0
    doc = json.loads(cap.text())
    assert doc["mode"] == "dry_run" and len(doc["rows"]) == len(ADDRESSES)
    a10 = [r for r in doc["rows"] if r["code"] == "A10"]
    assert a10 == [{"code": "A10", "label": ef.mask(ADDRESSES["E2E_TEST_STAFF_EMAIL"]), "in_pool": True,
                    "enabled": True, "status": "CONFIRMED"}]
    assert "@" not in cap.text()


def test_the_three_a10e_rows_are_numbered():
    rows = ef.expected_rows(ADDRESSES)
    labels = [r.label for r in rows if r.code == "A10e"]
    assert len(labels) == 3 and len(set(labels)) == 3 and all("#" in label for label in labels)


# ── --apply ──────────────────────────────────────────────────────────────────────────────────────

def test_apply_disables_and_signs_out_every_enabled_e2e_user_then_reads_back(idp, out):
    client, stub = idp
    o, cap = out
    owner = _user(ADDRESSES["E2E_OWNER_TEST_STAFF_EMAIL"], username="user-owner-zz")
    stray = _user(f"zz-stray@{DOMAIN}", username="user-stray-zz")
    off = _user(ADDRESSES["E2E_CIS_ADMIN_TEST_STAFF_EMAIL"], enabled=False, username="user-admin-zz")
    _list(stub, [owner, stray, off])
    for name in ("user-owner-zz", "user-stray-zz"):     # never the one already disabled
        stub.add_response("admin_disable_user", {}, {"UserPoolId": POOL, "Username": name})
        stub.add_response("admin_user_global_sign_out", {}, {"UserPoolId": POOL, "Username": name})
    _list(stub, [{**owner, "Enabled": False}, {**stray, "Enabled": False}, off])
    assert ef.run(client, POOL, o, apply=True, as_json=False, addresses=ADDRESSES) == 0
    stub.assert_no_pending_responses()
    text = cap.text()
    assert "read-back:" in text and "done: every E2E user in the pool is disabled" in text
    assert "@" not in text and "user-owner-zz" not in text


def test_apply_is_incomplete_when_one_stays_enabled(idp, out):
    client, stub = idp
    o, cap = out
    owner = _user(ADDRESSES["E2E_OWNER_TEST_STAFF_EMAIL"], username="user-owner-zz")
    _list(stub, [owner])
    stub.add_client_error("admin_disable_user", service_error_code="NotAuthorizedException",
                          expected_params={"UserPoolId": POOL, "Username": "user-owner-zz"})
    _list(stub, [owner])
    assert ef.run(client, POOL, o, apply=True, as_json=False, addresses=ADDRESSES) == 1
    assert "INCOMPLETE" in cap.text() and "FAILED A10h" in cap.text() and "user-owner-zz" not in cap.text()


def test_main_redacts_errors_and_never_prints_a_traceback(idp, out):
    client, stub = idp
    o, cap = out
    stub.add_client_error("list_users", service_error_code="ResourceNotFoundException",
                          service_message=f"pool {POOL} not found")
    assert ef.main(["--pool-id", POOL], out=o, idp=client) == 1
    assert "ERROR" in cap.text() and "Traceback" not in cap.text()
