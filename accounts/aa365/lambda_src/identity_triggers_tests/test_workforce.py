from __future__ import annotations

import json
import re
from pathlib import Path

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
    attrs = {"email": "admin@adventure.asia", "email_verified": "true"}
    workforce.pre_token_generation(token_event(attrs, ["cis-admin", "booking-admin"], client_id="bg"))
    lines = [json.loads(line) for line in capsys.readouterr().out.splitlines()]
    assert {"event": "breakglass_token_issued", "client_id": "bg",
            "trigger": "TokenGeneration_HostedAuth"} in lines


def test_custom_staff_groups_env(monkeypatch):
    monkeypatch.setenv("STAFF_GROUPS", "cis-admin")
    out = workforce.pre_token_generation(token_event(STAFF, ["cis-admin", "booking-sales"]))
    assert out["response"]["claimsAndScopeOverrideDetails"]["groupOverrideDetails"]["groupsToOverride"] == ["cis-admin"]


def test_booking_content_creator_group_kept_by_default():
    # S241 Q4/Q5 (AA-854): every Booking staff role (AA-Booking STAFF_ROLES) has a WORKFORCE group.
    out = workforce.pre_token_generation(token_event(STAFF, ["booking-content_creator", "rogue"]))
    details = out["response"]["claimsAndScopeOverrideDetails"]
    assert details["groupOverrideDetails"]["groupsToOverride"] == ["booking-content_creator"]


def test_default_staff_groups_match_terraform_groups():
    # Guard: the trigger's fallback list and the Terraform groups (identity.tf id_staff_groups) must
    # not drift; Terraform passes the same keys as STAFF_GROUPS, the default is only a fallback.
    tf = (Path(__file__).resolve().parents[2] / "identity.tf").read_text()
    block = re.search(r"id_staff_groups = \{(.*?)\n  \}", tf, re.S).group(1)
    tf_groups = set(re.findall(r'^\s*"([a-z_-]+)"\s*=', block, re.M))
    assert tf_groups == set(workforce.DEFAULT_STAFF_GROUPS.split(","))
    booking_roles = {"admin", "sales", "contracting", "content_creator"}
    assert {g.removeprefix("booking-") for g in tf_groups if g.startswith("booking-")} == booking_roles


# ------------------------------------------------------------------ TEMPORARY E2E test address (AA-816)
E2E = "e2e@e2e-mail.lumiguides.it.com"
E2E_ATTRS = {"email": E2E, "email_verified": "true"}
BOOKING_E2E = "e2e-booking@e2e-mail.lumiguides.it.com"
BOOKING_E2E_ATTRS = {"email": BOOKING_E2E, "email_verified": "true"}


def test_e2e_constant_is_the_one_test_address():
    assert workforce.E2E_TEST_STAFF_EMAIL == E2E
    assert workforce.E2E_TEST_STAFF_GROUPS == ("cis-reviewer",)


def test_e2e_allow_map_is_exactly_the_two_test_addresses():
    # Guard (AA-910): a new entry or a wider group set must be a reviewed change of this test too.
    assert dict(workforce.E2E_TEST_STAFF) == {
        E2E: ("cis-reviewer",),
        BOOKING_E2E: ("booking-admin",),
    }
    # Every key is already normalised (the lookup is on the lower-cased address).
    assert all(k == k.strip().lower() for k in workforce.E2E_TEST_STAFF)


def test_e2e_allow_map_is_read_only():
    with pytest.raises(TypeError):
        workforce.E2E_TEST_STAFF["x@e2e-mail.lumiguides.it.com"] = ("cis-admin",)  # type: ignore[index]


@pytest.mark.parametrize("email", [E2E, "E2E@E2E-Mail.Lumiguides.IT.com"])
def test_e2e_test_address_may_be_admin_created(email):
    out = workforce.pre_sign_up(admin_create(email))
    assert out["response"] == {"autoConfirmUser": False, "autoVerifyEmail": False, "autoVerifyPhone": False}


@pytest.mark.parametrize("email", [
    "e2e2@e2e-mail.lumiguides.it.com",
    "x.e2e@e2e-mail.lumiguides.it.com",
    "e2e@lumiguides.it.com",
    "e2e@e2e-mail.lumiguides.it.com.evil.com",
    "e2e@x.e2e-mail.lumiguides.it.com",
])
def test_other_addresses_near_the_e2e_one_are_still_denied(email):
    denied(workforce.pre_sign_up, admin_create(email))
    denied(workforce.pre_token_generation, token_event({"email": email, "email_verified": "true"}, ["cis-reviewer"]))


def test_e2e_self_sign_up_is_still_denied():
    event = sign_up_event("PreSignUp_SignUp", user_name=E2E, attrs={"email": E2E})
    denied(workforce.pre_sign_up, event)


def test_e2e_missing_domain_config_still_fails_closed(monkeypatch):
    monkeypatch.setenv("ALLOWED_EMAIL_DOMAIN", "")
    denied(workforce.pre_sign_up, admin_create(E2E))
    denied(workforce.pre_token_generation, token_event(E2E_ATTRS, ["cis-reviewer"]))


@pytest.mark.parametrize("source", ["TokenGeneration_HostedAuth", "TokenGeneration_RefreshTokens"])
def test_e2e_reviewer_gets_a_token(source, capsys):
    out = workforce.pre_token_generation(token_event(E2E_ATTRS, ["cis-reviewer", "rogue"], source=source))
    details = out["response"]["claimsAndScopeOverrideDetails"]
    assert details["groupOverrideDetails"]["groupsToOverride"] == ["cis-reviewer"]
    assert details["accessTokenGeneration"]["claimsToAddOrOverride"] == {"email": E2E}
    lines = [json.loads(line) for line in capsys.readouterr().out.splitlines()]
    assert any(line["event"] == "workforce_e2e_test_token_issued" for line in lines)


@pytest.mark.parametrize("groups", [
    ["cis-admin"],
    ["cis-content"],
    ["cis-reviewer", "cis-admin"],
    ["cis-reviewer", "booking-sales"],
    ["booking-admin"],
    [],
    ["rogue"],
])
def test_e2e_with_any_other_staff_group_is_denied(groups):
    denied(workforce.pre_token_generation, token_event(E2E_ATTRS, groups))


def test_e2e_unverified_email_is_denied():
    denied(workforce.pre_token_generation, token_event({"email": E2E, "email_verified": "false"}, ["cis-reviewer"]))


def test_e2e_token_log_names_the_account(capsys):
    workforce.pre_token_generation(token_event(E2E_ATTRS, ["cis-reviewer"], client_id="cis"))
    lines = [json.loads(line) for line in capsys.readouterr().out.splitlines()]
    assert {"event": "workforce_e2e_test_token_issued", "trigger": "TokenGeneration_HostedAuth",
            "client_id": "cis", "email": E2E} in lines


# ------------------------------------------------------------------ TEMPORARY Booking E2E test address (AA-910)
def test_booking_e2e_constant():
    assert workforce.E2E_BOOKING_TEST_STAFF_EMAIL == BOOKING_E2E
    assert workforce.E2E_BOOKING_TEST_STAFF_GROUPS == ("booking-admin",)


@pytest.mark.parametrize("email", [BOOKING_E2E, "E2E-Booking@E2E-Mail.Lumiguides.IT.com"])
def test_booking_e2e_address_may_be_admin_created(email, capsys):
    out = workforce.pre_sign_up(admin_create(email))
    assert out["response"] == {"autoConfirmUser": False, "autoVerifyEmail": False, "autoVerifyPhone": False}
    lines = [json.loads(line) for line in capsys.readouterr().out.splitlines()]
    assert {"event": "workforce_e2e_test_create_allowed", "email": BOOKING_E2E} in lines


@pytest.mark.parametrize("email", [
    "e2e-booking2@e2e-mail.lumiguides.it.com",
    "e2e-booking@lumiguides.it.com",
    "e2e-booking@e2e-mail.lumiguides.it.com.evil.com",
    "e2e-booking@x.e2e-mail.lumiguides.it.com",
    "e2e-bookings@e2e-mail.lumiguides.it.com",
    "booking@e2e-mail.lumiguides.it.com",
    "e2e-booking-admin@e2e-mail.lumiguides.it.com",
    "e2e-test-crm-atlas-owner@e2e-mail.lumiguides.it.com",  # CRM e2e users are EXTERNAL/partner-pool only
])
def test_other_addresses_near_the_booking_e2e_one_are_still_denied(email):
    denied(workforce.pre_sign_up, admin_create(email))
    denied(workforce.pre_token_generation, token_event({"email": email, "email_verified": "true"}, ["booking-admin"]))


def test_booking_e2e_self_sign_up_is_still_denied():
    event = sign_up_event("PreSignUp_SignUp", user_name=BOOKING_E2E, attrs={"email": BOOKING_E2E})
    denied(workforce.pre_sign_up, event)


@pytest.mark.parametrize("user_name", ["Google_1", "Facebook_42"])
def test_booking_e2e_federated_sign_in_is_still_denied(user_name):
    event = sign_up_event("PreSignUp_ExternalProvider", user_name=user_name,
                          attrs={"email": BOOKING_E2E, "email_verified": "true"})
    denied(workforce.pre_sign_up, event)


def test_booking_e2e_missing_domain_config_still_fails_closed(monkeypatch):
    monkeypatch.setenv("ALLOWED_EMAIL_DOMAIN", "")
    denied(workforce.pre_sign_up, admin_create(BOOKING_E2E))
    denied(workforce.pre_token_generation, token_event(BOOKING_E2E_ATTRS, ["booking-admin"]))


@pytest.mark.parametrize("source", ["TokenGeneration_HostedAuth", "TokenGeneration_RefreshTokens"])
def test_booking_e2e_admin_gets_a_token(source, capsys):
    out = workforce.pre_token_generation(
        token_event(BOOKING_E2E_ATTRS, ["booking-admin", "rogue"], source=source, client_id="booking-staff"))
    details = out["response"]["claimsAndScopeOverrideDetails"]
    assert details["groupOverrideDetails"]["groupsToOverride"] == ["booking-admin"]
    assert details["accessTokenGeneration"]["claimsToAddOrOverride"] == {"email": BOOKING_E2E}
    lines = [json.loads(line) for line in capsys.readouterr().out.splitlines()]
    assert {"event": "workforce_e2e_test_token_issued", "trigger": source,
            "client_id": "booking-staff", "email": BOOKING_E2E} in lines


@pytest.mark.parametrize("groups", [
    ["cis-reviewer"],             # the CIS E2E account's set does not transfer
    ["cis-admin"],
    ["booking-admin", "cis-reviewer"],
    ["booking-admin", "booking-sales"],
    ["booking-admin", "crm-platform-admin"],
    ["booking-sales"],
    ["booking-contracting"],
    ["booking-content_creator"],
    ["crm-platform-admin"],
    [],
    ["rogue"],
])
def test_booking_e2e_with_any_other_staff_group_is_denied(groups, capsys):
    denied(workforce.pre_token_generation, token_event(BOOKING_E2E_ATTRS, groups))
    lines = [json.loads(line) for line in capsys.readouterr().out.splitlines()]
    assert any(line["event"] == "workforce_pre_token_denied" for line in lines)
    assert not any(line["event"] == "workforce_e2e_test_token_issued" for line in lines)


def test_booking_e2e_unverified_email_is_denied():
    denied(workforce.pre_token_generation,
           token_event({"email": BOOKING_E2E, "email_verified": "false"}, ["booking-admin"]))


def test_cis_e2e_cannot_borrow_the_booking_group():
    # The map is per address: the CIS E2E account with booking-admin is still refused.
    denied(workforce.pre_token_generation, token_event(E2E_ATTRS, ["booking-admin"]))


def test_booking_e2e_address_is_a_mailbox_recipient():
    # Guard (AA-910): the SES receipt rule (e2e_mailbox.tf) must accept mail for every WORKFORCE E2E address, or
    # Cognito's sign-in code bounces and the E2E sign-in cannot finish.
    tf = (Path(__file__).resolve().parents[2] / "e2e_mailbox.tf").read_text()
    domain = re.search(r'e2e_mail_domain\s*=\s*"([^"$]+)\$\{var\.dns_zone_name\}"', tf).group(1)
    locals_ = dict(re.findall(r'^\s*(e2e_mail_\w*recipient)\s*=\s*"([^"@]+)@\$\{local\.e2e_mail_domain\}"', tf, re.M))
    rule = re.search(r"recipients\s*=\s*concat\(\[([^\]]*)\]", tf).group(1)
    in_rule = {locals_[name] for name in re.findall(r"local\.(e2e_mail_\w*recipient)\b", rule)}
    assert domain == "e2e-mail."
    assert {email.split("@", 1)[0] for email in workforce.E2E_TEST_STAFF} == in_rule
    assert all(email.endswith("@e2e-mail.lumiguides.it.com") for email in workforce.E2E_TEST_STAFF)
