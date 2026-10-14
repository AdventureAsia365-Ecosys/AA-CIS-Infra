from __future__ import annotations

import json

import pytest

import workforce
from conftest import sign_up_event, token_event


def denied(fn, *args, **kwargs):
    with pytest.raises(Exception) as exc:
        fn(*args, **kwargs)
    assert str(exc.value) == "Not authorised for AA staff sign-in"


def admin_create(email="staff@adventure.asia"):
    return sign_up_event("PreSignUp_AdminCreateUser", user_name=email, attrs={"email": email})


# ------------------------------------------------------------------ pre sign-up: directory only
def test_admin_create_user_in_domain_is_allowed():
    event = admin_create()
    event["response"]["autoConfirmUser"] = True  # must be forced back off
    event["response"]["autoVerifyEmail"] = True
    out = workforce.pre_sign_up(event)
    assert out["response"] == {"autoConfirmUser": False, "autoVerifyEmail": False, "autoVerifyPhone": False}


def test_admin_create_user_email_is_case_insensitive():
    workforce.pre_sign_up(admin_create("Staff@Adventure.Asia"))


@pytest.mark.parametrize("email", [
    "x@gmail.com",
    "staff@adventure.asia.evil.com",
    "staff@evil-adventure.asia",
    'a"b@adventure.asia',
    "a\\b@adventure.asia",
    "",
    None,
])
def test_admin_create_outside_domain_or_malformed_is_denied(email):
    attrs = {} if email is None else {"email": email}
    event = sign_up_event("PreSignUp_AdminCreateUser", user_name="u", attrs=attrs)
    denied(workforce.pre_sign_up, event)


@pytest.mark.parametrize("user_name", ["Google_1234567890", "google_1", "Facebook_42", "SignInWithApple_7"])
def test_any_federated_first_sign_in_is_denied(user_name):
    # ADR 0006 (accepted S236): staff sign in with an email code only; no social IdP on WORKFORCE.
    event = sign_up_event("PreSignUp_ExternalProvider", user_name=user_name,
                          attrs={"email": "staff@adventure.asia", "email_verified": "true"})
    denied(workforce.pre_sign_up, event)


@pytest.mark.parametrize("source", ["PreSignUp_SignUp", "Something_Else", None])
def test_self_sign_up_and_unknown_sources_are_denied(source):
    event = sign_up_event(source, user_name="x@adventure.asia", attrs={"email": "x@adventure.asia"})
    denied(workforce.pre_sign_up, event)


def test_missing_domain_config_fails_closed(monkeypatch):
    monkeypatch.setenv("ALLOWED_EMAIL_DOMAIN", "")
    denied(workforce.pre_sign_up, admin_create())


def test_unexpected_event_shape_fails_closed():
    event = admin_create()
    event["request"] = "not-a-dict"
    denied(workforce.pre_sign_up, event)


# ------------------------------------------------------------------ pre token generation
STAFF = {"email": "staff@adventure.asia", "email_verified": "true"}


def test_token_keeps_only_staff_groups_and_adds_email():
    out = workforce.pre_token_generation(token_event(STAFF, ["cis-admin", "rogue", "booking-sales"]))
    details = out["response"]["claimsAndScopeOverrideDetails"]
    assert details["groupOverrideDetails"]["groupsToOverride"] == ["booking-sales", "cis-admin"]
    assert details["accessTokenGeneration"]["claimsToAddOrOverride"] == {"email": "staff@adventure.asia"}


@pytest.mark.parametrize("source", ["TokenGeneration_RefreshTokens", "TokenGeneration_Authentication"])
def test_token_rules_apply_on_refresh_too(source):
    denied(workforce.pre_token_generation, token_event(STAFF, ["rogue"], source=source))


@pytest.mark.parametrize("attrs,groups", [
    (STAFF, []),
    (STAFF, ["tenant-owner"]),
    ({"email": "x@gmail.com", "email_verified": "true"}, ["cis-admin"]),
    ({"email": "staff@adventure.asia", "email_verified": "false"}, ["cis-admin"]),
    ({"email_verified": "true"}, ["cis-admin"]),
])
def test_token_denied(attrs, groups):
    denied(workforce.pre_token_generation, token_event(attrs, groups))


def test_breakglass_token_logs_alarm_line(capsys):
    attrs = {"email": "breakglass@adventure.asia", "email_verified": "true"}
    workforce.pre_token_generation(token_event(attrs, ["cis-admin", "booking-admin"], client_id="bg"))
    lines = [json.loads(line) for line in capsys.readouterr().out.splitlines()]
    assert {"event": "breakglass_token_issued", "client_id": "bg",
            "trigger": "TokenGeneration_HostedAuth"} in lines


def test_custom_staff_groups_env(monkeypatch):
    monkeypatch.setenv("STAFF_GROUPS", "cis-admin")
    out = workforce.pre_token_generation(token_event(STAFF, ["cis-admin", "booking-sales"]))
    assert out["response"]["claimsAndScopeOverrideDetails"]["groupOverrideDetails"]["groupsToOverride"] == ["cis-admin"]
