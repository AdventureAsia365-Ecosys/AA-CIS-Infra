"""AA-1111 S2 (root ADR 0006c): staff-totp-enroll and staff-totp-check of workforce_bootstrap.py.

botocore Stubber only (no AWS). The person's password and code come from injected prompts; the TOTP setup key reaches
only the reveal channel (never stdout / stderr through Output); the user is signed out but never disabled."""

from __future__ import annotations

import pytest
from botocore.stub import ANY

import workforce_bootstrap as wb
from conftest import CIS_CLIENT_ID, CLIENT_SECRET, POOL, fake_jwt

STAFF = "staff.one@adventure.asia"
SUB = "22222222-aaaa-bbbb-cccc-000000000002"
SEED = "JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP"
PASSWORD = "Pw-Typed-By-Person-AAbb11!!-xyz"
REFRESH = "REFRESH-TOKEN-STAFF-0123456789"
S1 = "session-one-0123456789abcdef"
CLIENTS_PAGE = {"UserPoolClients": [
    {"ClientId": CIS_CLIENT_ID, "UserPoolId": POOL, "ClientName": "aa-workforce-dev-cis-admin"},
]}


def staff_token(amr=None):
    claims = {"sub": SUB, "iss": f"https://cognito-idp.us-west-1.amazonaws.com/{POOL}", "token_use": "access",
              "client_id": CIS_CLIENT_ID, "cognito:groups": ["cis-admin"], "email": STAFF, "iat": 1, "exp": 901,
              "jti": "JTI-SHOULD-NOT-PRINT"}
    if amr is not None:
        claims["amr"] = amr
        claims["acr"] = "urn:cognito:loa:4" if "otp" in amr else "urn:cognito:loa:2"
    return fake_jwt(claims)


def result(token):
    return {"AuthenticationResult": {"AccessToken": token, "RefreshToken": REFRESH, "ExpiresIn": 900,
                                     "TokenType": "Bearer"}}


def prompts(ctx, secrets, texts):
    secrets, texts, shown = list(secrets), list(texts), []
    ctx.ask_secret = lambda _prompt: secrets.pop(0)
    ctx.ask_text = lambda _prompt: texts.pop(0)
    ctx.reveal = shown.append
    return shown


def stub_user(idp_stub, mfa=None, enabled=True):
    idp_stub.add_response("list_users", {"Users": [{"Username": SUB, "Enabled": enabled}]},
                          {"UserPoolId": POOL, "Filter": f'email = "{STAFF}"', "Limit": 2})
    if mfa is not None:
        idp_stub.add_response("admin_get_user", {"Username": SUB, "UserMFASettingList": mfa},
                              {"UserPoolId": POOL, "Username": STAFF})


def stub_client(idp_stub):
    idp_stub.add_response("list_user_pool_clients", CLIENTS_PAGE, {"UserPoolId": POOL, "MaxResults": ANY})
    idp_stub.add_response("describe_user_pool_client",
                          {"UserPoolClient": {"ClientId": CIS_CLIENT_ID, "ClientSecret": CLIENT_SECRET}},
                          {"UserPoolId": POOL, "ClientId": CIS_CLIENT_ID})


def stub_sign_out(idp_stub):
    idp_stub.add_response("revoke_token", {},
                          {"Token": REFRESH, "ClientId": CIS_CLIENT_ID, "ClientSecret": CLIENT_SECRET})
    idp_stub.add_response("admin_user_global_sign_out", {}, {"UserPoolId": POOL, "Username": STAFF})


def stub_password_sign_in(idp_stub, response):
    idp_stub.add_response("initiate_auth", response, {
        "AuthFlow": "USER_AUTH", "ClientId": CIS_CLIENT_ID,
        "AuthParameters": {"USERNAME": STAFF, "PREFERRED_CHALLENGE": "PASSWORD", "PASSWORD": PASSWORD,
                           "SECRET_HASH": wb.secret_hash(STAFF, CIS_CLIENT_ID, CLIENT_SECRET)}})


def _enroll_stubs(idp_stub, *, existing=False, codes_ok=(True,)):
    stub_user(idp_stub, mfa=["SOFTWARE_TOKEN_MFA"] if existing else [])
    stub_client(idp_stub)
    if existing:
        idp_stub.add_response("admin_set_user_mfa_preference", {}, {
            "UserPoolId": POOL, "Username": STAFF,
            "SoftwareTokenMfaSettings": {"Enabled": False, "PreferredMfa": False}})
    idp_stub.add_response("admin_set_user_password", {}, {
        "UserPoolId": POOL, "Username": STAFF, "Password": PASSWORD, "Permanent": True})
    stub_password_sign_in(idp_stub, result(staff_token(["pwd"])))
    idp_stub.add_response("associate_software_token", {"SecretCode": SEED}, {"AccessToken": ANY})
    for ok in codes_ok:
        idp_stub.add_response("verify_software_token", {"Status": "SUCCESS" if ok else "ERROR"},
                              {"AccessToken": ANY, "UserCode": ANY, "FriendlyDeviceName": "authenticator"})
    if codes_ok[-1]:
        idp_stub.add_response("admin_set_user_mfa_preference", {}, {
            "UserPoolId": POOL, "Username": STAFF,
            "SoftwareTokenMfaSettings": {"Enabled": True, "PreferredMfa": True}})
    stub_sign_out(idp_stub)


@pytest.mark.parametrize("existing", [False, True], ids=["first", "rotate"])
def test_enroll_sets_the_password_shows_the_key_once_and_never_disables(stubbed, ctx_factory, capsys, existing):
    _, idp_stub, _, _ = stubbed
    _enroll_stubs(idp_stub, existing=existing)
    ctx = ctx_factory()
    shown = prompts(ctx, [PASSWORD, PASSWORD], ["123456"])
    assert wb.cmd_staff_totp_enroll(ctx, STAFF, "cis-admin", existing, wb.DEFAULT_BREAKGLASS_EMAIL) == 0
    idp_stub.assert_no_pending_responses()  # no admin_disable_user anywhere
    revealed = "\n".join(shown)
    assert "JBSW Y3DP" in revealed and f"secret={SEED}" in revealed and "issuer=AA+Staff+%28dev%29" in revealed
    out = capsys.readouterr()
    for value in (PASSWORD, SEED, CLIENT_SECRET, REFRESH, "123456"):
        assert value not in out.out + out.err
    assert "TOTP enrolled, verified and preferred" in out.out and "DISABLED" not in out.out


def test_enroll_retries_a_wrong_code_then_succeeds(stubbed, ctx_factory):
    _, idp_stub, _, _ = stubbed
    _enroll_stubs(idp_stub, codes_ok=(False, True))
    ctx = ctx_factory()
    prompts(ctx, [PASSWORD, PASSWORD], ["000000", "123456"])
    assert wb.cmd_staff_totp_enroll(ctx, STAFF, "cis-admin", False, wb.DEFAULT_BREAKGLASS_EMAIL) == 0
    idp_stub.assert_no_pending_responses()


def test_enroll_gives_up_after_three_wrong_codes_and_still_signs_out(stubbed, ctx_factory):
    _, idp_stub, _, _ = stubbed
    _enroll_stubs(idp_stub, codes_ok=(False, False, False))
    ctx = ctx_factory()
    prompts(ctx, [PASSWORD, PASSWORD], ["000000", "000001", "000002"])
    with pytest.raises(wb.ToolError, match="TOTP not verified"):
        wb.cmd_staff_totp_enroll(ctx, STAFF, "cis-admin", False, wb.DEFAULT_BREAKGLASS_EMAIL)
    idp_stub.assert_no_pending_responses()


def test_enroll_refuses_an_enrolled_user_without_rotate_before_any_change(stubbed, ctx_factory):
    _, idp_stub, _, _ = stubbed
    stub_user(idp_stub, mfa=["SOFTWARE_TOKEN_MFA"])
    ctx = ctx_factory()
    prompts(ctx, [], [])
    with pytest.raises(wb.ToolError, match="already has TOTP"):
        wb.cmd_staff_totp_enroll(ctx, STAFF, "cis-admin", False, wb.DEFAULT_BREAKGLASS_EMAIL)
    idp_stub.assert_no_pending_responses()


@pytest.mark.parametrize("secrets, says", [
    ([PASSWORD, PASSWORD + "x"], "differ"),
    (["Short-1!", "Short-1!"], "at least 16"),
])
def test_enroll_refuses_a_bad_password_before_any_change(stubbed, ctx_factory, secrets, says):
    _, idp_stub, _, _ = stubbed
    stub_user(idp_stub, mfa=[])
    stub_client(idp_stub)
    ctx = ctx_factory()
    prompts(ctx, secrets, [])
    with pytest.raises(wb.ToolError, match=says):
        wb.cmd_staff_totp_enroll(ctx, STAFF, "cis-admin", False, wb.DEFAULT_BREAKGLASS_EMAIL)
    idp_stub.assert_no_pending_responses()


def test_enroll_refuses_break_glass_other_domains_and_clients(stubbed, ctx_factory):
    ctx = ctx_factory()
    with pytest.raises(wb.ToolError, match="break-glass"):
        wb.cmd_staff_totp_enroll(ctx, wb.DEFAULT_BREAKGLASS_EMAIL, "cis-admin", False, wb.DEFAULT_BREAKGLASS_EMAIL)
    with pytest.raises(wb.ToolError):
        wb.cmd_staff_totp_enroll(ctx, "someone@example.com", "cis-admin", False, wb.DEFAULT_BREAKGLASS_EMAIL)
    with pytest.raises(wb.ToolError, match="--client"):
        wb._staff_client(ctx, "breakglass")


@pytest.mark.parametrize("amr, code", [(["pwd", "otp", "mfa"], 0), (["pwd"], 1)], ids=["otp", "no-otp"])
def test_check_prints_amr_and_exits_by_it(stubbed, ctx_factory, capsys, amr, code):
    _, idp_stub, _, _ = stubbed
    stub_user(idp_stub)
    stub_client(idp_stub)
    stub_password_sign_in(idp_stub, {"ChallengeName": "SOFTWARE_TOKEN_MFA", "Session": S1,
                                     "ChallengeParameters": {"USERNAME": SUB}})
    idp_stub.add_response("respond_to_auth_challenge", result(staff_token(amr)), {
        "ClientId": CIS_CLIENT_ID, "ChallengeName": "SOFTWARE_TOKEN_MFA", "Session": S1,
        "ChallengeResponses": {"USERNAME": SUB, "SECRET_HASH": wb.secret_hash(SUB, CIS_CLIENT_ID, CLIENT_SECRET),
                               "SOFTWARE_TOKEN_MFA_CODE": "654321"}})
    stub_sign_out(idp_stub)
    ctx = ctx_factory()
    prompts(ctx, [PASSWORD], ["654321"])
    assert wb.cmd_staff_totp_check(ctx, STAFF, "cis-admin", wb.DEFAULT_BREAKGLASS_EMAIL) == code
    idp_stub.assert_no_pending_responses()
    out = capsys.readouterr()
    assert '  amr = ' in out.out and "JTI-SHOULD-NOT-PRINT" not in out.out
    assert PASSWORD not in out.out + out.err and "654321" not in out.out + out.err
    assert ("staff-totp-check: OK" in out.out) if code == 0 else ("do NOT turn" in out.err)


def test_otpauth_uri_shape():
    uri = wb.otpauth_uri(STAFF, SEED, "dev")
    assert uri.startswith("otpauth://totp/AA%20Staff%20%28dev%29%3Astaff.one%40adventure.asia?")
    assert "secret=" + SEED in uri and "digits=6" in uri and "period=30" in uri and "algorithm=SHA1" in uri
