from __future__ import annotations

import pytest

import external
from conftest import FakeCognito, federated_user, native_user, sign_up_event, token_event

CLIENTS = {
    "portal-id": "aa-external-dev-cis-portal",
    "tp-id": "aa-external-dev-tripplanner",
    "bk-id": "aa-external-dev-booking-customer",
    "rogue-id": "some-other-client",
}


@pytest.fixture(autouse=True)
def clear_cache():
    external._client_name_cache.clear()


def cognito(users=None, **kwargs):
    return FakeCognito(users=users, clients=CLIENTS, **kwargs)


def denied(fn, *args, **kwargs):
    with pytest.raises(Exception) as exc:
        fn(*args, **kwargs)
    assert str(exc.value) == "Sign-in is not available for this account"


GOOGLE = {"email": "Traveller@Example.com", "email_verified": "true"}


def google(client_id="tp-id", attrs=None, sub="555"):
    return sign_up_event("PreSignUp_ExternalProvider", user_name=f"Google_{sub}",
                         attrs=dict(GOOGLE if attrs is None else attrs), client_id=client_id)


def native_signup(client_id="tp-id", attrs=None):
    return sign_up_event("PreSignUp_SignUp", user_name="traveller@example.com",
                         attrs={"email": "traveller@example.com"} if attrs is None else attrs, client_id=client_id)


# ------------------------------------------------------------------ client-aware decisions
def test_admin_create_user_is_allowed_without_client():
    event = sign_up_event("PreSignUp_AdminCreateUser", attrs={"email": "t@example.com"},
                          client_id="CLIENT_ID_NOT_APPLICABLE")
    event["response"]["autoVerifyEmail"] = True
    out = external.pre_sign_up(event, cognito=cognito())
    assert out["response"]["autoVerifyEmail"] is False


@pytest.mark.parametrize("event", [native_signup("portal-id"), google("portal-id")])
def test_portal_refuses_every_self_sign_up(event):
    denied(external.pre_sign_up, event, cognito=cognito())


@pytest.mark.parametrize("client_id", ["rogue-id", None, "CLIENT_ID_NOT_APPLICABLE"])
def test_unknown_or_missing_client_fails_closed(client_id):
    denied(external.pre_sign_up, native_signup(client_id), cognito=cognito())


def test_describe_client_error_fails_closed():
    c = cognito()
    c.clients = {}
    denied(external.pre_sign_up, native_signup("tp-id"), cognito=c)


def test_client_name_is_cached():
    c = cognito()
    external.pre_sign_up(native_signup("tp-id"), cognito=c)
    external.pre_sign_up(native_signup("tp-id"), cognito=c)
    assert len(c.describe_calls) == 1


@pytest.mark.parametrize("client_id", ["tp-id", "bk-id"])
def test_traveller_native_sign_up_allowed_never_auto_confirmed(client_id):
    out = external.pre_sign_up(native_signup(client_id), cognito=cognito())
    assert out["response"] == {"autoConfirmUser": False, "autoVerifyEmail": False, "autoVerifyPhone": False}


@pytest.mark.parametrize("attrs", [
    {"email": "t@example.com", "email_verified": "true"},
    {"email": "t@example.com", "custom:hd": "adventure.asia"},
    {"email": 't"@example.com'},
    {},
])
def test_traveller_native_sign_up_cannot_self_verify_or_inject(attrs):
    denied(external.pre_sign_up, native_signup("tp-id", attrs), cognito=cognito())


def test_unknown_trigger_source_denied():
    event = sign_up_event("PreSignUp_Whatever", client_id="tp-id")
    denied(external.pre_sign_up, event, cognito=cognito())


# ------------------------------------------------------------------ linking rules (decision 6)
def test_google_links_to_confirmed_verified_native_user():
    c = cognito(users=[native_user("traveller@example.com")])
    external.pre_sign_up(google(), cognito=c)
    assert c.link_calls[0]["SourceUser"]["ProviderAttributeValue"] == "555"


def test_google_without_native_user_gets_own_profile():
    c = cognito(users=[federated_user("traveller@example.com", sub="777")])
    external.pre_sign_up(google(), cognito=c)
    assert c.link_calls == []


@pytest.mark.parametrize("user", [
    native_user("traveller@example.com", status="UNCONFIRMED"),
    native_user("traveller@example.com", verified="false"),
    native_user("traveller@example.com", enabled=False),
    native_user("traveller@example.com", status="FORCE_CHANGE_PASSWORD"),
    native_user("traveller@example.com", identities=[{"providerName": "Google", "userId": "other"}]),
])
def test_ineligible_targets_are_not_linked_but_sign_up_proceeds(user):
    c = cognito(users=[user])
    external.pre_sign_up(google(), cognito=c)
    assert c.link_calls == []


def test_unverified_google_email_is_not_linked():
    c = cognito(users=[native_user("traveller@example.com")])
    external.pre_sign_up(google(attrs={"email": "traveller@example.com", "email_verified": "false"}), cognito=c)
    assert c.link_calls == [] and c.list_calls == []


def test_retry_is_idempotent():
    c = cognito(users=[native_user("traveller@example.com",
                                   identities=[{"providerName": "Google", "userId": "555"}])])
    external.pre_sign_up(google(), cognito=c)
    assert c.link_calls == []


def test_facebook_is_never_linked():
    c = cognito(users=[native_user("traveller@example.com")])
    event = sign_up_event("PreSignUp_ExternalProvider", user_name="Facebook_42",
                          attrs={"email": "traveller@example.com"}, client_id="bk-id")
    external.pre_sign_up(event, cognito=c)
    assert c.link_calls == [] and c.list_calls == []


def test_unknown_provider_denied():
    event = sign_up_event("PreSignUp_ExternalProvider", user_name="SignInWithApple_1",
                          attrs=GOOGLE, client_id="tp-id")
    denied(external.pre_sign_up, event, cognito=cognito())


def test_list_users_error_fails_closed():
    denied(external.pre_sign_up, google(), cognito=cognito(fail_list=True))


# ------------------------------------------------------------------ pre token generation
def test_token_strips_groups_and_adds_email_claims():
    out = external.pre_token_generation(token_event(
        {"email": "T@Example.com", "email_verified": "true"}, ["cis-admin"]))
    details = out["response"]["claimsAndScopeOverrideDetails"]
    assert details["groupOverrideDetails"]["groupsToOverride"] == []
    assert details["accessTokenGeneration"]["claimsToAddOrOverride"] == {
        "email": "t@example.com", "email_verified": "true"}


def test_token_unverified_email_flagged_false():
    out = external.pre_token_generation(token_event({"email": "t@example.com"}, []))
    claims = out["response"]["claimsAndScopeOverrideDetails"]["accessTokenGeneration"]["claimsToAddOrOverride"]
    assert claims["email_verified"] == "false"


def test_token_without_email_facebook_user():
    out = external.pre_token_generation(token_event({}, [], source="TokenGeneration_RefreshTokens"))
    claims = out["response"]["claimsAndScopeOverrideDetails"]["accessTokenGeneration"]["claimsToAddOrOverride"]
    assert claims == {"email_verified": "false"}


def test_token_unsafe_email_fails_closed():
    denied(external.pre_token_generation, token_event({"email": 'a"b@x.com'}, []))


def test_native_sign_up_refused_until_email_otp_is_live(monkeypatch):
    monkeypatch.setenv("NATIVE_SIGNUP_ENABLED", "false")
    denied(external.pre_sign_up, native_signup("tp-id"), cognito=cognito())


def test_native_sign_up_flag_defaults_to_closed(monkeypatch):
    monkeypatch.delenv("NATIVE_SIGNUP_ENABLED")
    denied(external.pre_sign_up, native_signup("tp-id"), cognito=cognito())


def test_federated_sign_up_does_not_depend_on_native_flag(monkeypatch):
    monkeypatch.setenv("NATIVE_SIGNUP_ENABLED", "false")
    c = cognito(users=[native_user("traveller@example.com")])
    external.pre_sign_up(google(), cognito=c)
    assert len(c.link_calls) == 1
