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
    "e2e-test-studio-viewer@e2e-mail.lumiguides.it.com",  # AA-979 studio invitees are partner-pool only
    # Non-ASCII look-alikes. U+212A KELVIN SIGN lower-cases to ASCII 'k' (the fold that would alias the entry);
    # zero-width space and fullwidth 'k' do not fold but must not match either.
    "e2e-boo\u212aing@e2e-mail.lumiguides.it.com",
    "E2E-BOO\u212aING@E2E-MAIL.LUMIGUIDES.IT.COM",
    "e2e-boo\u200bking@e2e-mail.lumiguides.it.com",
    "e2e-boo\uff4bing@e2e-mail.lumiguides.it.com",
])
def test_other_addresses_near_the_booking_e2e_one_are_still_denied(email, capsys):
    denied(workforce.pre_sign_up, admin_create(email))
    denied(workforce.pre_token_generation, token_event({"email": email, "email_verified": "true"}, ["booking-admin"]))
    events = {json.loads(line)["event"] for line in capsys.readouterr().out.splitlines()}
    assert "workforce_e2e_test_create_allowed" not in events
    assert "workforce_e2e_test_token_issued" not in events


def test_kelvin_sign_really_folds_to_the_booking_address():
    # Keeps the look-alike case above honest: without the ASCII-only lookup this address would match the map.
    kelvin = "e2e-boo\u212aing@e2e-mail.lumiguides.it.com"
    assert kelvin.lower() == BOOKING_E2E  # the fold happens, so the ASCII check must see the raw value
    assert workforce._e2e_groups(kelvin, kelvin.lower()) is None
    assert workforce._e2e_groups(None, BOOKING_E2E) is None
    assert workforce._e2e_groups(BOOKING_E2E, BOOKING_E2E) == ("booking-admin",)


def test_booking_e2e_denied_when_staff_groups_override_drops_booking_admin(monkeypatch, capsys):
    # A STAFF_GROUPS override without booking-admin strips the only group, so the token is refused (never issued
    # with an empty or different group set).
    monkeypatch.setenv("STAFF_GROUPS", "cis-admin,cis-reviewer,booking-sales")
    denied(workforce.pre_token_generation, token_event(BOOKING_E2E_ATTRS, ["booking-admin"]))
    lines = [json.loads(line) for line in capsys.readouterr().out.splitlines()]
    assert any(line["event"] == "workforce_pre_token_denied" for line in lines)
    assert not any(line["event"] == "workforce_e2e_test_token_issued" for line in lines)


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


# ------------------------------------------------------------------ A10b: Dev-only CIS admin E2E address (AA-816, S252)
CIS_ADMIN_E2E = "e2e-cis-admin@e2e-mail.lumiguides.it.com"
CIS_ADMIN_E2E_ATTRS = {"email": CIS_ADMIN_E2E, "email_verified": "true"}
FLAG = "E2E_DEV_ONLY_STAFF_ENABLED"
CRM_STAFF_E2E = "e2e-crm-staff@e2e-mail.lumiguides.it.com"
CRM_STAFF_E2E_ATTRS = {"email": CRM_STAFF_E2E, "email_verified": "true"}


@pytest.fixture
def dev_flag_on(monkeypatch):
    monkeypatch.setenv(FLAG, "true")


def _events(capsys):
    return [json.loads(line) for line in capsys.readouterr().out.splitlines()]


def test_cis_admin_e2e_constants_and_dev_only_map():
    assert workforce.E2E_CIS_ADMIN_TEST_STAFF_EMAIL == CIS_ADMIN_E2E
    assert workforce.E2E_CIS_ADMIN_TEST_STAFF_GROUPS == ("cis-admin",)
    # Guard: the dev-only map is exactly the one address, and the always-on map did not gain it.
    assert dict(workforce.E2E_DEV_ONLY_TEST_STAFF) == {CIS_ADMIN_E2E: ("cis-admin",), CRM_STAFF_E2E: ("crm-ops", "crm-support")}
    assert CIS_ADMIN_E2E not in workforce.E2E_TEST_STAFF
    assert set(workforce.E2E_TEST_STAFF) == {E2E, BOOKING_E2E}
    assert workforce.DEV_ONLY_E2E_FLAG == FLAG and workforce.DEV_ONLY_E2E_ON == "true"


def test_dev_only_map_is_read_only():
    with pytest.raises(TypeError):
        workforce.E2E_DEV_ONLY_TEST_STAFF["x@e2e-mail.lumiguides.it.com"] = ("cis-admin",)  # type: ignore[index]
    with pytest.raises(TypeError):
        workforce.E2E_DEV_ONLY_TEST_STAFF[CIS_ADMIN_E2E] = ("cis-admin", "booking-admin")  # type: ignore[index]


@pytest.mark.parametrize("email", [CIS_ADMIN_E2E, "E2E-CIS-Admin@E2E-Mail.Lumiguides.IT.com"])
def test_cis_admin_e2e_may_be_admin_created_with_the_flag(email, dev_flag_on, capsys):
    out = workforce.pre_sign_up(admin_create(email))
    assert out["response"] == {"autoConfirmUser": False, "autoVerifyEmail": False, "autoVerifyPhone": False}
    assert {"event": "workforce_e2e_test_create_allowed", "email": CIS_ADMIN_E2E} in _events(capsys)


@pytest.mark.parametrize("source", ["TokenGeneration_HostedAuth", "TokenGeneration_RefreshTokens"])
def test_cis_admin_e2e_gets_a_cis_admin_token_with_the_flag(source, dev_flag_on, capsys):
    out = workforce.pre_token_generation(
        token_event(CIS_ADMIN_E2E_ATTRS, ["cis-admin", "rogue"], source=source, client_id="cis"))
    details = out["response"]["claimsAndScopeOverrideDetails"]
    assert details["groupOverrideDetails"]["groupsToOverride"] == ["cis-admin"]
    assert details["accessTokenGeneration"]["claimsToAddOrOverride"] == {"email": CIS_ADMIN_E2E}
    assert {"event": "workforce_e2e_test_token_issued", "trigger": source, "client_id": "cis",
            "email": CIS_ADMIN_E2E} in _events(capsys)


@pytest.mark.parametrize("value", [None, "", "false", "True", "TRUE", " true", "true ", "1", "yes", "on"])
def test_cis_admin_e2e_is_denied_unless_the_flag_is_exactly_true(value, monkeypatch, capsys):
    if value is None:
        monkeypatch.delenv(FLAG, raising=False)
    else:
        monkeypatch.setenv(FLAG, value)
    assert workforce._dev_only_e2e_enabled() is False
    denied(workforce.pre_sign_up, admin_create(CIS_ADMIN_E2E))
    denied(workforce.pre_token_generation, token_event(CIS_ADMIN_E2E_ATTRS, ["cis-admin"]))
    events = {e["event"] for e in _events(capsys)}
    assert "workforce_e2e_test_create_allowed" not in events and "workforce_e2e_test_token_issued" not in events


def test_the_flag_is_read_per_call(monkeypatch):
    monkeypatch.setenv(FLAG, "true")
    assert workforce._e2e_groups(CIS_ADMIN_E2E, CIS_ADMIN_E2E) == ("cis-admin",)
    monkeypatch.setenv(FLAG, "false")
    assert workforce._e2e_groups(CIS_ADMIN_E2E, CIS_ADMIN_E2E) is None


def test_the_flag_does_not_change_the_always_on_entries(monkeypatch):
    for value in ("true", "false"):
        monkeypatch.setenv(FLAG, value)
        assert workforce._e2e_groups(E2E, E2E) == ("cis-reviewer",)
        assert workforce._e2e_groups(BOOKING_E2E, BOOKING_E2E) == ("booking-admin",)


@pytest.mark.parametrize("groups", [
    ["cis-reviewer"],
    ["cis-content"],
    ["cis-admin", "cis-reviewer"],
    ["cis-admin", "booking-admin"],
    ["cis-admin", "booking-sales"],
    ["cis-admin", "crm-platform-admin"],
    ["cis-admin", "crm-ops"],
    ["booking-admin"],
    ["crm-platform-admin"],
    [],
    ["rogue"],
])
def test_cis_admin_e2e_with_any_other_group_set_is_denied(groups, dev_flag_on, capsys):
    denied(workforce.pre_token_generation, token_event(CIS_ADMIN_E2E_ATTRS, groups))
    events = _events(capsys)
    assert any(e["event"] == "workforce_pre_token_denied" for e in events)
    assert not any(e["event"] == "workforce_e2e_test_token_issued" for e in events)


def test_cis_admin_e2e_denied_when_staff_groups_override_drops_cis_admin(dev_flag_on, monkeypatch):
    monkeypatch.setenv("STAFF_GROUPS", "cis-reviewer,booking-admin")
    denied(workforce.pre_token_generation, token_event(CIS_ADMIN_E2E_ATTRS, ["cis-admin"]))


def test_cis_admin_e2e_unverified_email_is_denied(dev_flag_on):
    denied(workforce.pre_token_generation,
           token_event({"email": CIS_ADMIN_E2E, "email_verified": "false"}, ["cis-admin"]))
    denied(workforce.pre_token_generation, token_event({"email": CIS_ADMIN_E2E}, ["cis-admin"]))


@pytest.mark.parametrize("source", ["PreSignUp_SignUp", "PreSignUp_ExternalProvider", None])
def test_cis_admin_e2e_self_sign_up_and_federated_are_denied(source, dev_flag_on):
    user_name = "Google_1" if source == "PreSignUp_ExternalProvider" else CIS_ADMIN_E2E
    event = sign_up_event(source, user_name=user_name, attrs={"email": CIS_ADMIN_E2E, "email_verified": "true"})
    denied(workforce.pre_sign_up, event)


def test_cis_admin_e2e_missing_domain_config_still_fails_closed(dev_flag_on, monkeypatch):
    monkeypatch.setenv("ALLOWED_EMAIL_DOMAIN", "")
    denied(workforce.pre_sign_up, admin_create(CIS_ADMIN_E2E))
    denied(workforce.pre_token_generation, token_event(CIS_ADMIN_E2E_ATTRS, ["cis-admin"]))


@pytest.mark.parametrize("email", [
    "e2e-cis-admin2@e2e-mail.lumiguides.it.com",
    "e2e-cis-admin+x@e2e-mail.lumiguides.it.com",
    "e2e-admin@e2e-mail.lumiguides.it.com",
    "e2e-cis-admin@x.e2e-mail.lumiguides.it.com",
    "e2e-cis-admin@e2e-mail.lumiguides.it.com.evil.com",
    "e2e-cis-admin@lumiguides.it.com",
    "admin@e2e-mail.lumiguides.it.com",
    # Non-ASCII look-alikes: zero-width space, fullwidth 'a', Kelvin sign.
    "e2e-cis-admin@e2e-mail.lumiguides.it.com​",
    "e2e-cis-ａdmin@e2e-mail.lumiguides.it.com",
    "E2E-CIS-ADMIN@E2E-MAIL.LUMIGUIDES.IT.COM​",
    "e2e-cis-admin@e2e-mail.lumiguides.it.Kom",
])
def test_look_alikes_of_the_cis_admin_address_are_denied(email, dev_flag_on, capsys):
    denied(workforce.pre_sign_up, admin_create(email))
    denied(workforce.pre_token_generation, token_event({"email": email, "email_verified": "true"}, ["cis-admin"]))
    events = {e["event"] for e in _events(capsys)}
    assert "workforce_e2e_test_create_allowed" not in events and "workforce_e2e_test_token_issued" not in events


def test_a_non_ascii_raw_value_never_reaches_the_dev_only_map(dev_flag_on):
    # The address has no 'k', so no known fold aliases it today; the guard must still hold for the dev-only map: a raw
    # value with any non-ASCII character never matches, even when its normalised form is the exact address.
    assert workforce._e2e_groups(CIS_ADMIN_E2E, CIS_ADMIN_E2E) == ("cis-admin",)
    assert workforce._e2e_groups("\u212a" + CIS_ADMIN_E2E, CIS_ADMIN_E2E) is None
    assert workforce._e2e_groups(CIS_ADMIN_E2E + "\u200b", CIS_ADMIN_E2E) is None
    assert workforce._e2e_groups(None, CIS_ADMIN_E2E) is None


@pytest.mark.parametrize("attrs", [E2E_ATTRS, BOOKING_E2E_ATTRS])
def test_the_other_e2e_accounts_cannot_borrow_cis_admin(attrs, dev_flag_on):
    denied(workforce.pre_token_generation, token_event(attrs, ["cis-admin"]))


def _mailbox_tf() -> str:
    """e2e_mailbox.tf without comment lines (comments name the prefixes too and must not satisfy a guard)."""
    text = (Path(__file__).resolve().parents[2] / "e2e_mailbox.tf").read_text()
    return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))


_TOP_LEVEL = re.compile(r"^(resource|data|output|locals|variable) ", re.M)


def _resource_block(tf: str, kind: str, name: str) -> str:
    start = tf.index(f'resource "{kind}" "{name}" {{')
    nxt = _TOP_LEVEL.search(tf, start + 1)
    return tf[start:nxt.start() if nxt else len(tf)]


def _statement(tf: str, sid: str) -> str:
    """From the statement's sid to the next statement (plain or dynamic) or the end of the document."""
    start = tf.index(f'sid       = "{sid}"')
    stops = [i for i in (tf.find("statement {", start), tf.find('dynamic "statement"', start),
                         tf.find('resource "aws_s3_bucket_policy"', start)) if i != -1]
    return tf[start:min(stops)]


def test_cis_admin_e2e_address_has_its_own_rule_and_prefix():
    # Guard (A10b): the admin address is the only recipient of e2e-cognito-admin, never one of e2e-cognito, and that
    # rule writes to inbound-admin/ only; the rule exists on dev only.
    tf = _mailbox_tf()
    locals_ = dict(re.findall(r'^\s*(e2e_mail_\w+)\s*=\s*"([^"]*)"', tf, re.M))
    assert locals_["e2e_mail_admin_recipient"] == "e2e-cis-admin@${local.e2e_mail_domain}"
    assert workforce.E2E_CIS_ADMIN_TEST_STAFF_EMAIL.split("@", 1)[0] == "e2e-cis-admin"
    assert locals_["e2e_mail_admin_prefix"] == "inbound-admin/" and locals_["e2e_mail_prefix"] == "inbound/"
    assert locals_["e2e_mail_admin_rule"] == "e2e-cognito-admin"
    assert re.search(r'^\s*e2e_admin_enabled\s*=\s*var\.environment == "dev"$', tf, re.M)

    cognito = _resource_block(tf, "aws_ses_receipt_rule", "e2e_cognito")
    recipients = re.search(r"recipients\s*=\s*(.*)", cognito).group(1)
    assert "admin_recipient" not in recipients
    assert "object_key_prefix = local.e2e_mail_prefix" in cognito

    admin = _resource_block(tf, "aws_ses_receipt_rule", "e2e_cognito_admin")
    assert "count         = local.e2e_admin_enabled ? 1 : 0" in admin
    assert re.search(r"recipients\s*=\s*\[local\.e2e_mail_admin_recipient, local\.e2e_mail_crm_staff_recipient\]", admin)
    assert locals_["e2e_mail_crm_staff_recipient"] == "e2e-crm-staff@${local.e2e_mail_domain}"
    assert "crm_staff_recipient" not in recipients
    assert "object_key_prefix = local.e2e_mail_admin_prefix" in admin
    assert 'tls_policy    = "Require"' in admin and "scan_enabled  = true" in admin
    assert "after         = aws_ses_receipt_rule.crm_ingest.name" in admin


def test_reader_policy_never_covers_the_admin_prefix():
    # Guard (A10b): the CI reader role's identity policy names inbound/ only (by the local), never the bucket wildcard,
    # "inbound*" or the admin prefix.
    reader = _resource_block(_mailbox_tf(), "aws_iam_role_policy", "e2e_mail_reader")
    assert "e2e_mail_admin_prefix" not in reader and "inbound-admin" not in reader
    assert '"${local.e2e_mail_prefix}*"' in reader
    assert 'Resource = "${aws_s3_bucket.e2e_mail.arn}/${local.e2e_mail_prefix}*"' in reader
    assert not re.search(r'arn\}/\*"|inbound\*', reader)
    assert "inbound-admin/x".startswith("inbound/") is False   # what the prefix string match relies on


def test_bucket_policy_denies_the_admin_prefix_to_everyone_but_the_mfa_admin():
    tf = _mailbox_tf()
    deny = _statement(tf, "DenyAdminPrefixReadsExceptMfaAdmin")
    assert 'effect    = "Deny"' in deny and "actions   = local.e2e_mail_object_reads" in deny
    assert 'resources = ["${aws_s3_bucket.e2e_mail.arn}/${local.e2e_mail_admin_prefix}*"]' in deny
    assert 'identifiers = ["*"]' in deny
    assert re.search(r'test\s*=\s*"StringNotEquals"\s*variable\s*=\s*"aws:PrincipalArn"\s*'
                     r'values\s*=\s*\[local\.id_breakglass_admin_role_arn\]', deny)
    assert "e2e_mail_reader_arn" not in deny
    # Unconditional: it is a plain statement, not inside the dev-only dynamic block.
    dyn = tf.index('dynamic "statement"')
    assert tf.index('sid       = "DenyAdminPrefixReadsExceptMfaAdmin"') > tf.index("content {", dyn)
    assert tf.rfind('dynamic "statement"', 0, tf.index('sid       = "DenyAdminPrefixReadsExceptMfaAdmin"')) == dyn
    block_end = tf.index("\n  }\n", tf.index("content {", dyn))
    assert tf.index('sid       = "DenyAdminPrefixReadsExceptMfaAdmin"') > block_end


def test_ses_put_statements_pair_rule_and_prefix():
    tf = _mailbox_tf()
    base = _statement(tf, "AllowSesPutFromE2eRule")
    assert 'resources = ["${aws_s3_bucket.e2e_mail.arn}/${local.e2e_mail_prefix}*"]' in base
    assert "values   = [local.e2e_mail_rule_arn]" in base and "admin" not in base
    admin = _statement(tf, "AllowSesPutFromE2eAdminRule")
    assert 'resources = ["${aws_s3_bucket.e2e_mail.arn}/${local.e2e_mail_admin_prefix}*"]' in admin
    assert "values   = [local.e2e_mail_admin_rule_arn]" in admin
    assert "for_each = local.e2e_admin_enabled ? [1] : []" in tf


def test_identity_tf_switches_the_flag_on_dev_only():
    tf = (Path(__file__).resolve().parents[2] / "identity.tf").read_text()
    env = re.search(r"id_workforce_env = \{(.*?)\n  \}", tf, re.S).group(1)
    assert re.search(r'E2E_DEV_ONLY_STAFF_ENABLED = var\.environment == "dev" \? "true" : "false"', env)
    fn = tf[tf.index('resource "aws_lambda_function" "identity_trigger"'):tf.index('resource "aws_lambda_alias"')]
    assert re.search(r'condition\s*=\s*var\.environment == "dev" \|\| '
                     r'lookup\(each\.value\.env, "E2E_DEV_ONLY_STAFF_ENABLED", "false"\) != "true"', fn)
    # The flag reaches the WORKFORCE triggers only.
    ext = re.search(r"id_external_env = \{(.*?)\n  \}", tf, re.S).group(1)
    assert "E2E_DEV_ONLY_STAFF_ENABLED" not in ext


# ------------------------------------------------------------------ A10c: Dev-only CRM staff E2E address (AA-1019, S262)
def test_crm_staff_e2e_constants():
    assert workforce.E2E_CRM_STAFF_TEST_STAFF_EMAIL == CRM_STAFF_E2E
    assert workforce.E2E_CRM_STAFF_TEST_STAFF_GROUPS == ("crm-ops", "crm-support")
    assert CRM_STAFF_E2E not in workforce.E2E_TEST_STAFF


@pytest.mark.parametrize("source", ["TokenGeneration_HostedAuth", "TokenGeneration_RefreshTokens"])
def test_crm_staff_e2e_gets_exactly_ops_and_support_with_the_flag(source, dev_flag_on, capsys):
    assert workforce.pre_sign_up(admin_create(CRM_STAFF_E2E))["response"]["autoConfirmUser"] is False
    out = workforce.pre_token_generation(
        token_event(CRM_STAFF_E2E_ATTRS, ["crm-support", "crm-ops", "rogue"], source=source, client_id="crm"))
    details = out["response"]["claimsAndScopeOverrideDetails"]
    assert details["groupOverrideDetails"]["groupsToOverride"] == ["crm-ops", "crm-support"]
    assert details["accessTokenGeneration"]["claimsToAddOrOverride"] == {"email": CRM_STAFF_E2E}
    assert {"event": "workforce_e2e_test_token_issued", "trigger": source, "client_id": "crm",
            "email": CRM_STAFF_E2E} in _events(capsys)


@pytest.mark.parametrize("groups", [
    ["crm-ops"],
    ["crm-support"],
    ["crm-ops", "crm-support", "crm-platform-admin"],
    ["crm-ops", "crm-support", "cis-admin"],
    ["crm-ops", "crm-support", "booking-admin"],
    ["cis-admin"],
    [],
])
def test_crm_staff_e2e_with_any_other_group_set_is_denied(groups, dev_flag_on):
    denied(workforce.pre_token_generation, token_event(CRM_STAFF_E2E_ATTRS, groups))


def test_crm_staff_e2e_is_denied_without_the_flag(monkeypatch):
    monkeypatch.setenv(FLAG, "false")
    denied(workforce.pre_sign_up, admin_create(CRM_STAFF_E2E))
    denied(workforce.pre_token_generation, token_event(CRM_STAFF_E2E_ATTRS, ["crm-ops", "crm-support"]))


@pytest.mark.parametrize("email", [
    "e2e-crm-staff2@e2e-mail.lumiguides.it.com",
    "e2e-crm-staff@e2e-mail.lumiguides.it.com.evil.com",
    "e2e-crm-staff@lumiguides.it.com",
    "e2e-crm-staff@e2e-mail.lumiguides.it.com\u200b",
])
def test_look_alikes_of_the_crm_staff_address_are_denied(email, dev_flag_on):
    denied(workforce.pre_sign_up, admin_create(email))
    denied(workforce.pre_token_generation, token_event({"email": email, "email_verified": "true"}, ["crm-ops", "crm-support"]))


@pytest.mark.parametrize("attrs", [E2E_ATTRS, BOOKING_E2E_ATTRS, CIS_ADMIN_E2E_ATTRS])
def test_the_other_e2e_accounts_cannot_borrow_the_crm_staff_groups(attrs, dev_flag_on):
    denied(workforce.pre_token_generation, token_event(attrs, ["crm-ops", "crm-support"]))
