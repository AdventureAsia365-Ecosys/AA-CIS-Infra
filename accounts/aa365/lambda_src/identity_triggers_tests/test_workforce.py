from __future__ import annotations

import json

import pytest

import workforce
from conftest import FakeCognito, federated_user, native_user, sign_up_event, token_event

GOOD_ATTRS = {
    "email": "Staff@Adventure.Asia",
    "email_verified": "true",
    "custom:hd": "adventure.asia",
}


def google_signup(attrs=None, user_name="Google_1234567890"):
    return sign_up_event("PreSignUp_ExternalProvider", user_name=user_name,
                         attrs=dict(GOOD_ATTRS if attrs is None else attrs))


def denied(fn, *args, **kwargs):
    with pytest.raises(Exception) as exc:
        fn(*args, **kwargs)
    assert str(exc.value) == "Not authorised for AA staff sign-in"


# ------------------------------------------------------------------ pre sign-up: happy paths
def test_google_first_sign_in_links_to_pre_created_native_user():
    cognito = FakeCognito(users=[native_user("staff@adventure.asia")])
    out = workforce.pre_sign_up(google_signup(), cognito=cognito)
    assert out["response"] == {"autoConfirmUser": False, "autoVerifyEmail": False, "autoVerifyPhone": False}
    assert cognito.list_calls[0]["Filter"] == 'email = "staff@adventure.asia"'
    link = cognito.link_calls[0]
    assert link["DestinationUser"] == {"ProviderName": "Cognito",
                                       "ProviderAttributeValue": "11111111-aaaa-bbbb-cccc-000000000001"}
    assert link["SourceUser"] == {"ProviderName": "Google", "ProviderAttributeName": "Cognito_Subject",
                                  "ProviderAttributeValue": "1234567890"}


def test_lower_case_federated_username_is_accepted():
    cognito = FakeCognito(users=[native_user("staff@adventure.asia")])
    workforce.pre_sign_up(google_signup(user_name="google_1234567890"), cognito=cognito)
    assert len(cognito.link_calls) == 1


def test_force_change_password_admin_created_user_is_a_target():
    cognito = FakeCognito(users=[native_user("staff@adventure.asia", status="FORCE_CHANGE_PASSWORD")])
    workforce.pre_sign_up(google_signup(), cognito=cognito)
    assert len(cognito.link_calls) == 1


def test_retry_after_link_is_idempotent():
    identities = [{"providerName": "Google", "userId": "1234567890"}]
    cognito = FakeCognito(users=[native_user("staff@adventure.asia", identities=identities)])
    workforce.pre_sign_up(google_signup(), cognito=cognito)
    assert cognito.link_calls == []


def test_admin_create_user_in_domain_is_allowed():
    event = sign_up_event("PreSignUp_AdminCreateUser", user_name="staff@adventure.asia",
                          attrs={"email": "staff@adventure.asia"})
    event["response"]["autoConfirmUser"] = True  # must be forced back off
    out = workforce.pre_sign_up(event, cognito=FakeCognito())
    assert out["response"]["autoConfirmUser"] is False


def test_hd_check_can_be_relaxed_explicitly(monkeypatch):
    monkeypatch.setenv("REQUIRE_HD", "false")
    attrs = {"email": "staff@adventure.asia", "email_verified": "true"}
    cognito = FakeCognito(users=[native_user("staff@adventure.asia")])
    workforce.pre_sign_up(google_signup(attrs), cognito=cognito)
    assert len(cognito.link_calls) == 1


# ------------------------------------------------------------------ pre sign-up: denials
@pytest.mark.parametrize("attrs", [
    {**GOOD_ATTRS, "custom:hd": "gmail.com"},
    {k: v for k, v in GOOD_ATTRS.items() if k != "custom:hd"},
    {**GOOD_ATTRS, "email_verified": "false"},
    {k: v for k, v in GOOD_ATTRS.items() if k != "email_verified"},
    {**GOOD_ATTRS, "email": "staff@adventure.asia.evil.com"},
    {**GOOD_ATTRS, "email": "staff@gmail.com"},
    {**GOOD_ATTRS, "email": 'a"b@adventure.asia'},
    {**GOOD_ATTRS, "email": "a\\b@adventure.asia"},
    {**GOOD_ATTRS, "email": ""},
    {k: v for k, v in GOOD_ATTRS.items() if k != "email"},
])
def test_bad_google_attributes_are_denied(attrs):
    cognito = FakeCognito(users=[native_user("staff@adventure.asia")])
    denied(workforce.pre_sign_up, google_signup(attrs), cognito=cognito)
    assert cognito.link_calls == []


def test_email_not_in_allow_list_is_denied():
    cognito = FakeCognito(users=[native_user("other@adventure.asia")])
    denied(workforce.pre_sign_up, google_signup(), cognito=cognito)


def test_only_a_federated_profile_with_the_email_is_not_an_allow_list_entry():
    cognito = FakeCognito(users=[federated_user("staff@adventure.asia")])
    denied(workforce.pre_sign_up, google_signup(), cognito=cognito)


@pytest.mark.parametrize("user", [
    native_user("staff@adventure.asia", enabled=False),
    native_user("staff@adventure.asia", status="UNCONFIRMED"),
    native_user("staff@adventure.asia", status="RESET_REQUIRED"),
    native_user("staff@adventure.asia", verified="false"),
    native_user("staff@adventure.asia", identities=[{"providerName": "Google", "userId": "other"}]),
])
def test_ineligible_target_is_denied(user):
    cognito = FakeCognito(users=[user])
    denied(workforce.pre_sign_up, google_signup(), cognito=cognito)
    assert cognito.link_calls == []


def test_unconfirmed_is_never_a_target_even_if_configured(monkeypatch):
    monkeypatch.setenv("LINK_TARGET_STATUSES", "CONFIRMED,UNCONFIRMED")
    cognito = FakeCognito(users=[native_user("staff@adventure.asia", status="UNCONFIRMED")])
    denied(workforce.pre_sign_up, google_signup(), cognito=cognito)


def test_paginated_list_users_is_denied():
    cognito = FakeCognito(users=[native_user("staff@adventure.asia")], paginated=True)
    denied(workforce.pre_sign_up, google_signup(), cognito=cognito)


def test_cognito_error_fails_closed():
    cognito = FakeCognito(users=[native_user("staff@adventure.asia")], fail_list=True)
    denied(workforce.pre_sign_up, google_signup(), cognito=cognito)


def test_two_native_users_are_denied():
    cognito = FakeCognito(users=[
        native_user("staff@adventure.asia", username="a"),
        native_user("STAFF@adventure.asia", username="b"),
    ])
    denied(workforce.pre_sign_up, google_signup(), cognito=cognito)


@pytest.mark.parametrize("source", ["PreSignUp_SignUp", "Something_Else", None])
def test_self_sign_up_and_unknown_sources_are_denied(source):
    event = sign_up_event(source, user_name="x@adventure.asia", attrs={"email": "x@adventure.asia"})
    denied(workforce.pre_sign_up, event, cognito=FakeCognito())


def test_facebook_is_denied():
    cognito = FakeCognito(users=[native_user("staff@adventure.asia")])
    denied(workforce.pre_sign_up, google_signup(user_name="Facebook_42"), cognito=cognito)


def test_admin_create_outside_domain_is_denied():
    event = sign_up_event("PreSignUp_AdminCreateUser", user_name="x@gmail.com", attrs={"email": "x@gmail.com"})
    denied(workforce.pre_sign_up, event, cognito=FakeCognito())


def test_missing_domain_config_fails_closed(monkeypatch):
    monkeypatch.setenv("ALLOWED_EMAIL_DOMAIN", "")
    cognito = FakeCognito(users=[native_user("staff@adventure.asia")])
    denied(workforce.pre_sign_up, google_signup(), cognito=cognito)


def test_invalid_boolean_config_fails_closed(monkeypatch):
    monkeypatch.setenv("REQUIRE_HD", "flase")
    cognito = FakeCognito(users=[native_user("staff@adventure.asia")])
    denied(workforce.pre_sign_up, google_signup(), cognito=cognito)


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
