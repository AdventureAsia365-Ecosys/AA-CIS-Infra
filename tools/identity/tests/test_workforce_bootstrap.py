"""Tests for tools/identity/workforce_bootstrap.py (AA-854 Phase 1 step I2)."""

from __future__ import annotations

import hashlib
import json
import os
import stat
import urllib.parse

import pytest
from botocore.stub import ANY

import workforce_bootstrap as wb
from conftest import BG_CLIENT_ID, CIS_CLIENT_ID, CLIENT_SECRET, POOL, FakeClock, fake_jwt

BG_EMAIL = "admin@adventure.asia"
STAFF_EMAIL = "nghieppham@adventure.asia"
USER_SUB = "11111111-aaaa-bbbb-cccc-000000000001"
SEED = "JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP"  # base32
PASSWORD = "Pw-Known-For-Test-AAbb11!!-xyz"
REFRESH = "REFRESH-TOKEN-VALUE-0123456789"
S1 = "session-one-0123456789abcdef"  # Cognito Session is >= 20 chars
S2 = "session-two-0123456789abcdef"
CLIENTS_PAGE = {"UserPoolClients": [
    {"ClientId": CIS_CLIENT_ID, "UserPoolId": POOL, "ClientName": "aa-workforce-dev-cis-admin"},
    {"ClientId": BG_CLIENT_ID, "UserPoolId": POOL, "ClientName": "aa-workforce-dev-breakglass"},
]}


def access_token(client_id=BG_CLIENT_ID, email=BG_EMAIL):
    return fake_jwt({
        "sub": USER_SUB, "iss": f"https://cognito-idp.us-west-1.amazonaws.com/{POOL}",
        "token_use": "access", "client_id": client_id, "cognito:groups": ["booking-admin", "cis-admin"],
        "email": email, "scope": "aws.cognito.signin.user.admin", "iat": 1_760_000_000,
        "exp": 1_760_000_900, "jti": "JTI-SHOULD-NOT-PRINT", "origin_jti": "ORIGIN-JTI-SHOULD-NOT-PRINT",
    })


def id_token(email=STAFF_EMAIL):
    return fake_jwt({
        "sub": USER_SUB, "token_use": "id", "aud": CIS_CLIENT_ID, "email": email,
        "email_verified": True, "at_hash": "AT-HASH-SHOULD-NOT-PRINT", "iat": 1, "exp": 901,
    })


def auth_result(token):
    return {"AuthenticationResult": {"AccessToken": token, "IdToken": id_token(BG_EMAIL),
                                     "RefreshToken": REFRESH, "ExpiresIn": 900, "TokenType": "Bearer"}}


def assert_clean(captured, *values):
    text = captured.out + captured.err
    for value in values:
        assert value not in text, f"secret leaked to output: {value[:6]}..."


def stub_close_out(idp_stub, username=BG_EMAIL, with_revoke=True, disable_fails=False):
    if with_revoke:
        idp_stub.add_response("revoke_token", {},
                              {"Token": REFRESH, "ClientId": BG_CLIENT_ID, "ClientSecret": CLIENT_SECRET})
    idp_stub.add_response("admin_user_global_sign_out", {}, {"UserPoolId": POOL, "Username": username})
    if disable_fails:
        idp_stub.add_client_error("admin_disable_user", service_error_code="InternalErrorException",
                                  http_status_code=500)
    else:
        idp_stub.add_response("admin_disable_user", {}, {"UserPoolId": POOL, "Username": username})


def stub_describe_secret(sm_stub):
    sm_stub.add_response("describe_secret", {"Name": "aa-identity/dev/breakglass"},
                         {"SecretId": "aa-identity/dev/breakglass"})


# --------------------------------------------------------------------------------------------
# RFC 6238 / TOTP
# --------------------------------------------------------------------------------------------
RFC6238_SHA1 = [  # RFC 6238 Appendix B, SHA1, key "12345678901234567890", 8 digits
    (59, "94287082"),
    (1111111109, "07081804"),
    (1111111111, "14050471"),
    (1234567890, "89005924"),
    (2000000000, "69279037"),
    (20000000000, "65353130"),
]
RFC6238_SHA256 = [  # same appendix, SHA256, 32-byte key
    (59, "46119246"),
    (1111111109, "68084774"),
    (1111111111, "67062674"),
    (1234567890, "91819424"),
    (2000000000, "90698825"),
    (20000000000, "77737706"),
]


@pytest.mark.parametrize("at,expected", RFC6238_SHA1)
def test_totp_rfc6238_sha1_vectors(at, expected):
    assert wb.totp(b"12345678901234567890", at, digits=8) == expected


@pytest.mark.parametrize("at,expected", RFC6238_SHA256)
def test_totp_rfc6238_sha256_vectors(at, expected):
    assert wb.totp(b"12345678901234567890123456789012", at, digits=8, digest=hashlib.sha256) == expected


def test_totp_six_digits_from_base32_seed():
    key = wb.b32decode_seed("gezdgnbvgy3tqojqgezdgnbvgy3tqojq")  # base32 of the RFC key, lower case
    assert key == b"12345678901234567890"
    assert wb.totp(key, 59) == "287082"
    assert wb.totp(key, 1111111109) == "081804"  # leading zero kept


def test_wait_for_fresh_window_sleeps_past_next_boundary():
    clock = FakeClock(1000.0)  # step 33 started at 990, next starts at 1020
    at = wb.wait_for_fresh_window(clock, clock.sleep)
    assert clock.sleeps == [21.0]
    assert at == 1021.0 and int(at // 30) == 34


# --------------------------------------------------------------------------------------------
# Pure helpers
# --------------------------------------------------------------------------------------------
def test_secret_hash_matches_cognito_definition():
    import base64
    import hmac
    expected = base64.b64encode(
        hmac.new(b"sek", b"user@adventure.asia" + b"cid", hashlib.sha256).digest()).decode()
    assert wb.secret_hash("user@adventure.asia", "cid", "sek") == expected


def test_generated_password_meets_pool_policy():
    for _ in range(50):
        pw = wb.generate_password()
        assert len(pw) >= 16
        assert any(c.islower() for c in pw) and any(c.isupper() for c in pw)
        assert any(c.isdigit() for c in pw) and any(c in wb.PASSWORD_SYMBOLS for c in pw)


@pytest.mark.parametrize("email", ["x@example.com", "a@adventure.asia.evil.com", "adventure.asia",
                                   "@adventure.asia", "a@sub.adventure.asia", ""])
def test_require_staff_email_refuses_out_of_domain(email):
    with pytest.raises(wb.ToolError, match="outside the staff domain"):
        wb.require_staff_email(email)


@pytest.mark.parametrize("email", ['a"b@adventure.asia', "a\\b@adventure.asia", "a b@adventure.asia",
                                   "a'b@adventure.asia"])
def test_require_staff_email_refuses_unsafe_local_part(email):
    with pytest.raises(wb.ToolError, match="unsupported character in the email local part"):
        wb.require_staff_email(email)


def test_require_staff_email_normalises():
    assert wb.require_staff_email("  NghiepPham@Adventure.Asia ") == STAFF_EMAIL


def test_parse_groups_rejects_unknown_and_empty():
    assert wb.parse_groups("cis-admin, booking-admin,cis-admin") == ["cis-admin", "booking-admin"]
    with pytest.raises(wb.ToolError, match="unknown group"):
        wb.parse_groups("cis-admin,platform-admin")
    with pytest.raises(wb.ToolError, match="at least one"):
        wb.parse_groups(" , ")


def test_staff_groups_match_terraform():
    tf = open(os.path.join(os.path.dirname(__file__), "..", "..", "..", "accounts", "aa365", "identity.tf")).read()
    block = tf.split("id_staff_groups = {", 1)[1].split("\n  }", 1)[0]
    for group in wb.STAFF_GROUPS:
        assert f'"{group}"' in block
    assert block.count("precedence") == len(wb.STAFF_GROUPS)


def test_output_redacts_registered_values(capsys):
    out = wb.Output()
    out.register("supersecretvalue", None, "")
    out.info("value=supersecretvalue end")
    out.warn("err supersecretvalue")
    captured = capsys.readouterr()
    assert "supersecretvalue" not in captured.out + captured.err
    assert "value=*** end" in captured.out


# --------------------------------------------------------------------------------------------
# create-staff (Stubber: SUPPRESS + email_verified always sent; out-of-domain refused client-side)
# --------------------------------------------------------------------------------------------
def test_create_staff_sends_suppress_and_email_verified(stubbed, ctx_factory, capsys):
    idp, idp_stub, _, _ = stubbed
    idp_stub.add_response("admin_create_user", {}, {
        "UserPoolId": POOL,
        "Username": STAFF_EMAIL,
        "UserAttributes": [{"Name": "email", "Value": STAFF_EMAIL},
                           {"Name": "email_verified", "Value": "true"}],
        "MessageAction": "SUPPRESS",
    })
    for group in ("cis-admin", "booking-admin"):
        idp_stub.add_response("admin_add_user_to_group", {},
                              {"UserPoolId": POOL, "Username": STAFF_EMAIL, "GroupName": group})
    rc = wb.cmd_create_staff(ctx_factory(), "NghiepPham@adventure.asia", "cis-admin,booking-admin",
                             None, BG_EMAIL)
    assert rc == 0
    idp_stub.assert_no_pending_responses()
    out = capsys.readouterr().out
    assert "created (SUPPRESS, email_verified=true, no password)" in out


def test_create_staff_with_name_still_suppressed(stubbed, ctx_factory):
    _, idp_stub, _, _ = stubbed
    idp_stub.add_response("admin_create_user", {}, {
        "UserPoolId": POOL, "Username": STAFF_EMAIL,
        "UserAttributes": [{"Name": "email", "Value": STAFF_EMAIL},
                           {"Name": "email_verified", "Value": "true"},
                           {"Name": "name", "Value": "Pham Quoc Nghiep"}],
        "MessageAction": "SUPPRESS",
    })
    idp_stub.add_response("admin_add_user_to_group", {},
                          {"UserPoolId": POOL, "Username": STAFF_EMAIL, "GroupName": "cis-reviewer"})
    assert wb.cmd_create_staff(ctx_factory(), STAFF_EMAIL, "cis-reviewer", "Pham Quoc Nghiep", BG_EMAIL) == 0
    idp_stub.assert_no_pending_responses()


def test_create_staff_existing_user_is_idempotent(stubbed, ctx_factory, capsys):
    _, idp_stub, _, _ = stubbed
    idp_stub.add_client_error("admin_create_user", service_error_code="UsernameExistsException",
                              http_status_code=400)
    idp_stub.add_response("admin_add_user_to_group", {},
                          {"UserPoolId": POOL, "Username": STAFF_EMAIL, "GroupName": "cis-admin"})
    assert wb.cmd_create_staff(ctx_factory(), STAFF_EMAIL, "cis-admin", None, BG_EMAIL) == 0
    idp_stub.assert_no_pending_responses()
    assert "already exists" in capsys.readouterr().out


def test_create_staff_refuses_out_of_domain_before_any_call(stubbed, ctx_factory):
    # No stubbed response: any AWS call would raise UnStubbedResponseError instead of ToolError.
    with pytest.raises(wb.ToolError, match="outside the staff domain"):
        wb.cmd_create_staff(ctx_factory(), "x@example.com", "cis-admin", None, BG_EMAIL)


def test_create_staff_refuses_breakglass_address(stubbed, ctx_factory):
    with pytest.raises(wb.ToolError, match="break-glass"):
        wb.cmd_create_staff(ctx_factory(), "Admin@adventure.asia", "cis-admin", None, BG_EMAIL)


def test_create_staff_trigger_refusal_test_reports_server_side_refusal(stubbed, ctx_factory, capsys):
    _, idp_stub, _, _ = stubbed
    idp_stub.add_client_error("admin_create_user", service_error_code="UserLambdaValidationException",
                              service_message="PreSignUp failed with error Not allowed.",
                              expected_params={
                                  "UserPoolId": POOL, "Username": "x@example.com",
                                  "UserAttributes": [{"Name": "email", "Value": "x@example.com"},
                                                     {"Name": "email_verified", "Value": "true"}],
                                  "MessageAction": "SUPPRESS",
                              })
    # No admin_add_user_to_group stubbed: a group call would fail the test.
    assert wb.cmd_create_staff(ctx_factory(), "X@example.com", "cis-admin", None, BG_EMAIL,
                               trigger_refusal_test=True) == 0
    idp_stub.assert_no_pending_responses()
    captured = capsys.readouterr()
    assert "client-side domain check skipped" in captured.err
    assert "refused server-side (UserLambdaValidationException): PreSignUp failed" in captured.out
    assert "refused client-side" not in captured.out + captured.err


def test_create_staff_trigger_refusal_test_disables_and_fails_if_trigger_accepts(stubbed, ctx_factory, capsys):
    _, idp_stub, _, _ = stubbed
    idp_stub.add_response("admin_create_user", {}, None)
    idp_stub.add_response("admin_disable_user", {}, {"UserPoolId": POOL, "Username": "x@example.com"})
    with pytest.raises(wb.ToolError, match="trigger did NOT refuse x@example.com: .*DISABLED"):
        wb.cmd_create_staff(ctx_factory(), "x@example.com", "cis-admin", None, BG_EMAIL,
                            trigger_refusal_test=True)
    idp_stub.assert_no_pending_responses()  # no group was added
    assert "OK" not in capsys.readouterr().out


def test_create_staff_trigger_refusal_test_refuses_staff_domain(stubbed, ctx_factory):
    with pytest.raises(wb.ToolError, match="OUTSIDE the staff domain"):
        wb.cmd_create_staff(ctx_factory(), STAFF_EMAIL, "cis-admin", None, BG_EMAIL, trigger_refusal_test=True)


def test_main_prints_one_line_error_and_exit_1(stubbed, monkeypatch, capsys):
    idp, _, sm, _ = stubbed
    monkeypatch.setattr(wb, "_aws_clients", lambda args, out: (idp, sm))
    rc = wb.main(["create-staff", "--email", "x@example.com", "--groups", "cis-admin"])
    assert rc == 1
    captured = capsys.readouterr()
    assert "ERROR refused client-side: address outside the staff domain" in captured.err
    assert "Traceback" not in captured.err


# --------------------------------------------------------------------------------------------
# breakglass-init
# --------------------------------------------------------------------------------------------
def _stub_init_happy(idp_stub, sm_stub, existing: bool):
    idp_stub.add_response("list_user_pool_clients", CLIENTS_PAGE, {"UserPoolId": POOL, "MaxResults": 60})
    stub_describe_secret(sm_stub)
    users = [{"Username": USER_SUB, "UserStatus": "CONFIRMED", "Enabled": False}] if existing else []
    idp_stub.add_response("list_users", {"Users": users},
                          {"UserPoolId": POOL, "Filter": f'email = "{BG_EMAIL}"', "Limit": 2})
    if not existing:
        idp_stub.add_response("admin_create_user", {}, {
            "UserPoolId": POOL, "Username": BG_EMAIL,
            "UserAttributes": [{"Name": "email", "Value": BG_EMAIL},
                               {"Name": "email_verified", "Value": "true"}],
            "MessageAction": "SUPPRESS",
        })
    for group in ("cis-admin", "booking-admin"):
        idp_stub.add_response("admin_add_user_to_group", {},
                              {"UserPoolId": POOL, "Username": BG_EMAIL, "GroupName": group})
    idp_stub.add_response("describe_user_pool_client",
                          {"UserPoolClient": {"ClientId": BG_CLIENT_ID, "ClientSecret": CLIENT_SECRET}},
                          {"UserPoolId": POOL, "ClientId": BG_CLIENT_ID})
    idp_stub.add_response("admin_enable_user", {}, {"UserPoolId": POOL, "Username": BG_EMAIL})
    if existing:
        idp_stub.add_response("admin_set_user_mfa_preference", {}, {
            "UserPoolId": POOL, "Username": BG_EMAIL,
            "SoftwareTokenMfaSettings": {"Enabled": False, "PreferredMfa": False}})
    idp_stub.add_response("admin_set_user_password", {}, {
        "UserPoolId": POOL, "Username": BG_EMAIL, "Password": PASSWORD, "Permanent": True})
    idp_stub.add_response("initiate_auth", auth_result(access_token()), {
        "AuthFlow": "USER_AUTH", "ClientId": BG_CLIENT_ID,
        "AuthParameters": {"USERNAME": BG_EMAIL, "PREFERRED_CHALLENGE": "PASSWORD", "PASSWORD": PASSWORD,
                           "SECRET_HASH": wb.secret_hash(BG_EMAIL, BG_CLIENT_ID, CLIENT_SECRET)}})
    idp_stub.add_response("associate_software_token", {"SecretCode": SEED}, {"AccessToken": ANY})
    idp_stub.add_response("verify_software_token", {"Status": "SUCCESS"},
                          {"AccessToken": ANY, "UserCode": ANY, "FriendlyDeviceName": "breakglass"})
    idp_stub.add_response("admin_set_user_mfa_preference", {}, {
        "UserPoolId": POOL, "Username": BG_EMAIL,
        "SoftwareTokenMfaSettings": {"Enabled": True, "PreferredMfa": True}})
    sm_stub.add_response("put_secret_value", {"VersionId": "a" * 32 + "-version"},
                         {"SecretId": "aa-identity/dev/breakglass", "SecretString": ANY})
    stub_close_out(idp_stub)


@pytest.mark.parametrize("existing", [False, True], ids=["first-run", "rotation"])
def test_breakglass_init_happy_path_no_secret_leak(stubbed, ctx_factory, monkeypatch, capsys, existing):
    idp, idp_stub, sm, sm_stub = stubbed
    monkeypatch.setattr(wb, "generate_password", lambda length=wb.PASSWORD_LENGTH: PASSWORD)
    captured_calls = {}
    sm.meta.events.register("provide-client-params.secrets-manager.PutSecretValue",
                            lambda params, **kw: captured_calls.update(put=dict(params)))
    idp.meta.events.register("provide-client-params.cognito-idp.VerifySoftwareToken",
                             lambda params, **kw: captured_calls.update(code=params["UserCode"]))
    _stub_init_happy(idp_stub, sm_stub, existing)
    ctx = ctx_factory()

    assert wb.cmd_breakglass_init(ctx, BG_EMAIL) == 0
    idp_stub.assert_no_pending_responses()
    sm_stub.assert_no_pending_responses()

    stored = json.loads(captured_calls["put"]["SecretString"])
    assert set(stored) == {"username", "password", "totp_seed", "created_at"}
    assert stored["username"] == BG_EMAIL and stored["password"] == PASSWORD and stored["totp_seed"] == SEED
    assert captured_calls["code"] == wb.totp(wb.b32decode_seed(SEED), ctx.clock())

    captured = capsys.readouterr()
    assert_clean(captured, PASSWORD, SEED, CLIENT_SECRET, REFRESH, access_token(), captured_calls["code"],
                 captured_calls["put"]["SecretString"])
    assert "VersionId " + "a" * 32 + "-version" in captured.out
    assert "user: DISABLED" in captured.out


def test_breakglass_init_failure_still_revokes_and_disables(stubbed, ctx_factory, monkeypatch, capsys):
    _, idp_stub, _, sm_stub = stubbed
    monkeypatch.setattr(wb, "generate_password", lambda length=wb.PASSWORD_LENGTH: PASSWORD)
    idp_stub.add_response("list_user_pool_clients", CLIENTS_PAGE, {"UserPoolId": POOL, "MaxResults": 60})
    stub_describe_secret(sm_stub)
    idp_stub.add_response("list_users", {"Users": []}, None)
    idp_stub.add_response("admin_create_user", {}, None)
    idp_stub.add_response("admin_add_user_to_group", {}, None)
    idp_stub.add_response("admin_add_user_to_group", {}, None)
    idp_stub.add_response("describe_user_pool_client",
                          {"UserPoolClient": {"ClientId": BG_CLIENT_ID, "ClientSecret": CLIENT_SECRET}}, None)
    idp_stub.add_response("admin_enable_user", {}, None)
    idp_stub.add_response("admin_set_user_password", {}, None)
    idp_stub.add_response("initiate_auth", auth_result(access_token()), None)
    idp_stub.add_response("associate_software_token", {"SecretCode": SEED}, None)
    idp_stub.add_client_error("verify_software_token", service_error_code="EnableSoftwareTokenMFAException",
                              http_status_code=400)
    stub_close_out(idp_stub)
    with pytest.raises(Exception, match="EnableSoftwareTokenMFAException"):
        wb.cmd_breakglass_init(ctx_factory(), BG_EMAIL)
    idp_stub.assert_no_pending_responses()  # revoke + sign-out + disable all ran
    captured = capsys.readouterr()
    assert "user: DISABLED" in captured.out
    assert "break-glass credentials NOT stored" in captured.err and "Re-run breakglass-init" in captured.err
    assert "breakglass-init: done" not in captured.out
    assert_clean(captured, PASSWORD, SEED, CLIENT_SECRET, REFRESH)


def test_breakglass_init_disable_runs_even_if_revoke_and_signout_fail(stubbed, ctx_factory, capsys):
    _, idp_stub, _, _ = stubbed
    idp_stub.add_client_error("revoke_token", service_error_code="InternalErrorException", http_status_code=500)
    idp_stub.add_client_error("admin_user_global_sign_out", service_error_code="TooManyRequestsException",
                              http_status_code=400)
    idp_stub.add_response("admin_disable_user", {}, {"UserPoolId": POOL, "Username": BG_EMAIL})
    failures = wb.close_out(ctx_factory().idp, pool_id=POOL, username=BG_EMAIL, client_id=BG_CLIENT_ID,
                            client_secret=CLIENT_SECRET, refresh_token=REFRESH, out=wb.Output())
    idp_stub.assert_no_pending_responses()
    assert len(failures) == 2
    captured = capsys.readouterr()
    assert "user: DISABLED" in captured.out and "Disable the user by hand" in captured.err
    assert_clean(captured, CLIENT_SECRET, REFRESH)


def test_breakglass_init_unknown_client_changes_nothing(stubbed, ctx_factory):
    _, idp_stub, _, _ = stubbed
    idp_stub.add_response("list_user_pool_clients", {"UserPoolClients": []}, None)
    with pytest.raises(wb.ToolError, match="aa-workforce-dev-breakglass"):
        wb.cmd_breakglass_init(ctx_factory(), BG_EMAIL)
    idp_stub.assert_no_pending_responses()


# --------------------------------------------------------------------------------------------
# breakglass-verify
# --------------------------------------------------------------------------------------------
def _stub_verify_start(idp_stub, sm_stub):
    idp_stub.add_response("list_user_pool_clients", CLIENTS_PAGE, None)
    sm_stub.add_response("get_secret_value", {
        "VersionId": "b" * 32 + "-version",
        "SecretString": json.dumps({"username": BG_EMAIL, "password": PASSWORD, "totp_seed": SEED,
                                    "created_at": "2026-10-18T00:00:00+00:00"})},
        {"SecretId": "aa-identity/dev/breakglass"})
    idp_stub.add_response("describe_user_pool_client",
                          {"UserPoolClient": {"ClientId": BG_CLIENT_ID, "ClientSecret": CLIENT_SECRET}}, None)
    idp_stub.add_response("admin_enable_user", {}, {"UserPoolId": POOL, "Username": BG_EMAIL})


def test_breakglass_verify_answers_mfa_in_fresh_window(stubbed, ctx_factory, capsys):
    _, idp_stub, _, sm_stub = stubbed
    clock = FakeClock(1_760_000_020.0)  # step began at ..._010 -> 10 s in, wait 21 s
    _stub_verify_start(idp_stub, sm_stub)
    idp_stub.add_response("initiate_auth", {
        "ChallengeName": "SOFTWARE_TOKEN_MFA", "Session": S1,
        "ChallengeParameters": {"USERNAME": USER_SUB}}, None)
    expected_code = wb.totp(wb.b32decode_seed(SEED), 1_760_000_041.0)
    idp_stub.add_response("respond_to_auth_challenge", auth_result(access_token()), {
        "ClientId": BG_CLIENT_ID, "ChallengeName": "SOFTWARE_TOKEN_MFA", "Session": S1,
        "ChallengeResponses": {"USERNAME": USER_SUB,
                               "SECRET_HASH": wb.secret_hash(USER_SUB, BG_CLIENT_ID, CLIENT_SECRET),
                               "SOFTWARE_TOKEN_MFA_CODE": expected_code}})
    stub_close_out(idp_stub)

    assert wb.cmd_breakglass_verify(ctx_factory(clock=clock), BG_EMAIL) == 0
    idp_stub.assert_no_pending_responses()
    sm_stub.assert_no_pending_responses()
    assert clock.sleeps == [21.0]
    captured = capsys.readouterr()
    assert 'token_use = "access"' in captured.out
    assert f'client_id = "{BG_CLIENT_ID}"' in captured.out
    assert 'cognito:groups = ["booking-admin", "cis-admin"]' in captured.out
    assert "JTI-SHOULD-NOT-PRINT" not in captured.out
    assert "breakglass-verify: OK" in captured.out
    assert_clean(captured, PASSWORD, SEED, CLIENT_SECRET, REFRESH, access_token(), expected_code)


def test_breakglass_verify_select_challenge_then_mfa(stubbed, ctx_factory, capsys):
    _, idp_stub, _, sm_stub = stubbed
    clock = FakeClock(1_760_000_000.0)
    _stub_verify_start(idp_stub, sm_stub)
    idp_stub.add_response("initiate_auth", {
        "ChallengeName": "SELECT_CHALLENGE", "Session": S1,
        "ChallengeParameters": {"USERNAME": USER_SUB}}, None)
    idp_stub.add_response("respond_to_auth_challenge", {
        "ChallengeName": "SOFTWARE_TOKEN_MFA", "Session": S2, "ChallengeParameters": {}}, {
        "ClientId": BG_CLIENT_ID, "ChallengeName": "SELECT_CHALLENGE", "Session": S1,
        "ChallengeResponses": {"USERNAME": USER_SUB, "ANSWER": "PASSWORD", "PASSWORD": PASSWORD,
                               "SECRET_HASH": wb.secret_hash(USER_SUB, BG_CLIENT_ID, CLIENT_SECRET)}})
    idp_stub.add_response("respond_to_auth_challenge", auth_result(access_token()), {
        "ClientId": BG_CLIENT_ID, "ChallengeName": "SOFTWARE_TOKEN_MFA", "Session": S2,
        "ChallengeResponses": ANY})
    stub_close_out(idp_stub)
    assert wb.cmd_breakglass_verify(ctx_factory(clock=clock), BG_EMAIL) == 0
    idp_stub.assert_no_pending_responses()
    assert_clean(capsys.readouterr(), PASSWORD, SEED, CLIENT_SECRET, REFRESH)


def test_breakglass_verify_password_challenge(stubbed, ctx_factory, capsys):
    _, idp_stub, _, sm_stub = stubbed
    _stub_verify_start(idp_stub, sm_stub)
    idp_stub.add_response("initiate_auth", {"ChallengeName": "PASSWORD", "Session": S1,
                                            "ChallengeParameters": {}}, None)
    idp_stub.add_response("respond_to_auth_challenge", {
        "ChallengeName": "SOFTWARE_TOKEN_MFA", "Session": S2, "ChallengeParameters": {}}, {
        "ClientId": BG_CLIENT_ID, "ChallengeName": "PASSWORD", "Session": S1,
        "ChallengeResponses": {"USERNAME": BG_EMAIL, "PASSWORD": PASSWORD,
                               "SECRET_HASH": wb.secret_hash(BG_EMAIL, BG_CLIENT_ID, CLIENT_SECRET)}})
    idp_stub.add_response("respond_to_auth_challenge", auth_result(access_token()), None)
    stub_close_out(idp_stub)
    assert wb.cmd_breakglass_verify(ctx_factory(), BG_EMAIL) == 0
    idp_stub.assert_no_pending_responses()
    assert_clean(capsys.readouterr(), PASSWORD, SEED, CLIENT_SECRET)


def test_breakglass_verify_unexpected_challenge_disables(stubbed, ctx_factory, capsys):
    _, idp_stub, _, sm_stub = stubbed
    _stub_verify_start(idp_stub, sm_stub)
    idp_stub.add_response("initiate_auth", {"ChallengeName": "NEW_PASSWORD_REQUIRED", "Session": S1,
                                            "ChallengeParameters": {}}, None)
    stub_close_out(idp_stub, with_revoke=False)
    with pytest.raises(wb.ToolError, match="NEW_PASSWORD_REQUIRED"):
        wb.cmd_breakglass_verify(ctx_factory(), BG_EMAIL)
    idp_stub.assert_no_pending_responses()
    assert "user: DISABLED" in capsys.readouterr().out


# --------------------------------------------------------------------------------------------
# authorize-url / exchange-code (spike helpers)
# --------------------------------------------------------------------------------------------
REDIRECT = "http://localhost:3000/api/auth/callback/cognito"


def _authorize(stubbed, ctx_factory, tmp_path, capsys):
    _, idp_stub, _, _ = stubbed
    idp_stub.add_response("list_user_pool_clients", CLIENTS_PAGE, None)
    assert wb.cmd_authorize_url(ctx_factory(), "cis-admin", REDIRECT, wb.DEFAULT_HOSTED_DOMAIN, tmp_path) == 0
    out = capsys.readouterr().out
    url = [line for line in out.splitlines() if line.startswith("https://")][0]
    return url, json.loads((tmp_path / "pkce-pending.json").read_text()), out


def test_authorize_url_pkce_s256_and_private_state_file(stubbed, ctx_factory, tmp_path, capsys):
    url, pending, out = _authorize(stubbed, ctx_factory, tmp_path, capsys)
    mode = stat.S_IMODE(os.stat(tmp_path / "pkce-pending.json").st_mode)
    assert mode == 0o600
    q = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
    assert url.startswith(wb.DEFAULT_HOSTED_DOMAIN + "/oauth2/authorize?")
    assert q["client_id"] == [CIS_CLIENT_ID] and q["redirect_uri"] == [REDIRECT]
    assert q["response_type"] == ["code"] and q["scope"] == ["openid email profile"]
    assert q["code_challenge_method"] == ["S256"] and q["state"] == [pending["state"]]
    assert q["code_challenge"] == [wb.b64url(hashlib.sha256(pending["code_verifier"].encode()).digest())]
    assert pending["code_verifier"] not in out
    assert 43 <= len(pending["code_verifier"]) <= 128


def test_exchange_code_refuses_wrong_state_without_http(stubbed, ctx_factory, tmp_path, capsys):
    _authorize(stubbed, ctx_factory, tmp_path, capsys)

    def no_http(*a, **k):
        raise AssertionError("no HTTP call expected")

    ctx = ctx_factory(http_post=no_http)
    with pytest.raises(wb.ToolError, match="state does not match"):
        wb.cmd_exchange_code(ctx, f"{REDIRECT}?code=CODE123456&state=forged", tmp_path)
    with pytest.raises(wb.ToolError, match="redirect_uri"):
        state = json.loads((tmp_path / "pkce-pending.json").read_text())["state"]
        wb.cmd_exchange_code(ctx, f"http://evil.example/api/auth/callback/cognito?code=C&state={state}", tmp_path)


def test_exchange_code_prints_only_safe_claims_and_revokes(stubbed, ctx_factory, tmp_path, capsys):
    _, pending, _ = _authorize(stubbed, ctx_factory, tmp_path, capsys)
    _, idp_stub, _, _ = stubbed
    idp_stub.add_response("describe_user_pool_client",
                          {"UserPoolClient": {"ClientId": CIS_CLIENT_ID, "ClientSecret": CLIENT_SECRET}},
                          {"UserPoolId": POOL, "ClientId": CIS_CLIENT_ID})
    at, it = access_token(CIS_CLIENT_ID, STAFF_EMAIL), id_token()
    calls = []

    def fake_post(url, form, basic):
        calls.append((url, dict(form), basic))
        if url.endswith("/oauth2/token"):
            return {"status": 200, "json": {"access_token": at, "id_token": it, "refresh_token": REFRESH,
                                            "expires_in": 900, "token_type": "Bearer"}}
        return {"status": 200, "json": {}}

    code = "AUTH-CODE-0123456789"
    rc = wb.cmd_exchange_code(ctx_factory(http_post=fake_post),
                              f"{REDIRECT}?code={code}&state={pending['state']}", tmp_path)
    assert rc == 0
    idp_stub.assert_no_pending_responses()
    assert not (tmp_path / "pkce-pending.json").exists()
    token_call, revoke_call = calls
    assert token_call[0] == wb.DEFAULT_HOSTED_DOMAIN + "/oauth2/token"
    assert token_call[1] == {"grant_type": "authorization_code", "client_id": CIS_CLIENT_ID, "code": code,
                             "redirect_uri": REDIRECT, "code_verifier": pending["code_verifier"]}
    assert token_call[2] == (CIS_CLIENT_ID, CLIENT_SECRET)
    assert revoke_call[0].endswith("/oauth2/revoke") and revoke_call[1]["token"] == REFRESH
    captured = capsys.readouterr()
    assert 'token_use = "access"' in captured.out and 'token_use = "id"' in captured.out
    assert f'email = "{STAFF_EMAIL}"' in captured.out
    assert "revoke: refresh token revoked" in captured.out
    assert_clean(captured, at, it, REFRESH, CLIENT_SECRET, code, pending["code_verifier"],
                 "JTI-SHOULD-NOT-PRINT", "AT-HASH-SHOULD-NOT-PRINT")


def test_exchange_code_reports_callback_error(stubbed, ctx_factory, tmp_path, capsys):
    _, pending, _ = _authorize(stubbed, ctx_factory, tmp_path, capsys)
    with pytest.raises(wb.ToolError, match="access_denied"):
        wb.cmd_exchange_code(ctx_factory(), f"{REDIRECT}?error=access_denied&state={pending['state']}", tmp_path)


def test_find_state_dir_walks_up_to_workspace(tmp_path):
    start = tmp_path / ".tmp-session" / "s999" / "wt" / "tools" / "identity"
    start.mkdir(parents=True)
    assert wb.find_state_dir(start) == tmp_path / ".tmp-session" / "identity-spike"
    plain = tmp_path / "infra" / "AA-CIS-Infra" / "tools" / "identity"
    plain.mkdir(parents=True)
    assert wb.find_state_dir(plain) == tmp_path / ".tmp-session" / "identity-spike"


def test_breakglass_init_rerun_after_partial_run_without_totp(stubbed, ctx_factory, monkeypatch, capsys):
    """A user left without TOTP by an earlier failed run: clearing the preference may be refused."""
    idp, idp_stub, sm, sm_stub = stubbed
    monkeypatch.setattr(wb, "generate_password", lambda length=wb.PASSWORD_LENGTH: PASSWORD)
    idp_stub.add_response("list_user_pool_clients", CLIENTS_PAGE, None)
    stub_describe_secret(sm_stub)
    idp_stub.add_response("list_users", {"Users": [{"Username": USER_SUB, "UserStatus": "FORCE_CHANGE_PASSWORD",
                                                    "Enabled": False}]}, None)
    idp_stub.add_response("admin_add_user_to_group", {}, None)
    idp_stub.add_response("admin_add_user_to_group", {}, None)
    idp_stub.add_response("describe_user_pool_client",
                          {"UserPoolClient": {"ClientId": BG_CLIENT_ID, "ClientSecret": CLIENT_SECRET}}, None)
    idp_stub.add_response("admin_enable_user", {}, None)
    idp_stub.add_client_error("admin_set_user_mfa_preference", service_error_code="InvalidParameterException",
                              http_status_code=400)
    idp_stub.add_response("admin_set_user_password", {}, None)
    idp_stub.add_response("initiate_auth", auth_result(access_token()), None)
    idp_stub.add_response("associate_software_token", {"SecretCode": SEED}, None)
    idp_stub.add_response("verify_software_token", {"Status": "SUCCESS"}, None)
    idp_stub.add_response("admin_set_user_mfa_preference", {}, None)
    sm_stub.add_response("put_secret_value", {"VersionId": "c" * 32 + "-version"}, None)
    stub_close_out(idp_stub)
    assert wb.cmd_breakglass_init(ctx_factory(), BG_EMAIL) == 0
    idp_stub.assert_no_pending_responses()
    captured = capsys.readouterr()
    assert "nothing to clear" in captured.out and "user: DISABLED" in captured.out
    assert_clean(captured, PASSWORD, SEED, CLIENT_SECRET, REFRESH)


# --------------------------------------------------------------------------------------------
# Review fixes (fail closed, preflight, ListUsers miss)
# --------------------------------------------------------------------------------------------
def _stub_init_until_signin(idp_stub, sm_stub):
    """First-run path up to and including the secret write (no close-out)."""
    idp_stub.add_response("list_user_pool_clients", CLIENTS_PAGE, None)
    stub_describe_secret(sm_stub)
    idp_stub.add_response("list_users", {"Users": []}, None)
    idp_stub.add_response("admin_create_user", {}, None)
    idp_stub.add_response("admin_add_user_to_group", {}, None)
    idp_stub.add_response("admin_add_user_to_group", {}, None)
    idp_stub.add_response("describe_user_pool_client",
                          {"UserPoolClient": {"ClientId": BG_CLIENT_ID, "ClientSecret": CLIENT_SECRET}}, None)
    idp_stub.add_response("admin_enable_user", {}, None)
    idp_stub.add_response("admin_set_user_password", {}, None)
    idp_stub.add_response("initiate_auth", auth_result(access_token()), None)
    idp_stub.add_response("associate_software_token", {"SecretCode": SEED}, None)
    idp_stub.add_response("verify_software_token", {"Status": "SUCCESS"}, None)
    idp_stub.add_response("admin_set_user_mfa_preference", {}, None)


def test_breakglass_init_failed_disable_exits_1_without_done(stubbed, monkeypatch, capsys):
    idp, idp_stub, sm, sm_stub = stubbed
    monkeypatch.setattr(wb, "generate_password", lambda length=wb.PASSWORD_LENGTH: PASSWORD)
    monkeypatch.setattr(wb, "_aws_clients", lambda args, out: (idp, sm))
    _stub_init_until_signin(idp_stub, sm_stub)
    sm_stub.add_response("put_secret_value", {"VersionId": "d" * 32 + "-version"}, None)
    stub_close_out(idp_stub, disable_fails=True)
    rc = wb.main(["--pool-id", POOL, "breakglass-init"])
    assert rc == 1
    idp_stub.assert_no_pending_responses()
    captured = capsys.readouterr()
    assert "breakglass-init: done" not in captured.out
    assert "user: DISABLED" not in captured.out
    assert "cleanup INCOMPLETE (admin_disable_user InternalErrorException)" in captured.err
    assert "WERE stored" in captured.err and "admin-disable-user" in captured.err
    assert_clean(captured, PASSWORD, SEED, CLIENT_SECRET, REFRESH)


def test_breakglass_verify_failed_disable_exits_1_without_ok(stubbed, monkeypatch, capsys):
    idp, idp_stub, sm, sm_stub = stubbed
    monkeypatch.setattr(wb, "_aws_clients", lambda args, out: (idp, sm))
    _stub_verify_start(idp_stub, sm_stub)
    idp_stub.add_response("initiate_auth", {"ChallengeName": "SOFTWARE_TOKEN_MFA", "Session": S1,
                                            "ChallengeParameters": {}}, None)
    idp_stub.add_response("respond_to_auth_challenge", auth_result(access_token()), None)
    stub_close_out(idp_stub, disable_fails=True)
    monkeypatch.setattr(wb, "wait_for_fresh_window", lambda clock, sleep, step=30: clock())  # no real sleep
    rc = wb.main(["--pool-id", POOL, "breakglass-verify"])
    assert rc == 1
    idp_stub.assert_no_pending_responses()
    captured = capsys.readouterr()
    assert "breakglass-verify: OK" not in captured.out
    assert "cleanup INCOMPLETE (admin_disable_user InternalErrorException)" in captured.err
    assert_clean(captured, PASSWORD, SEED, CLIENT_SECRET, REFRESH)


def test_breakglass_init_put_secret_denied_warns_not_stored(stubbed, ctx_factory, monkeypatch, capsys):
    _, idp_stub, _, sm_stub = stubbed
    monkeypatch.setattr(wb, "generate_password", lambda length=wb.PASSWORD_LENGTH: PASSWORD)
    _stub_init_until_signin(idp_stub, sm_stub)
    sm_stub.add_client_error("put_secret_value", service_error_code="AccessDeniedException", http_status_code=400)
    stub_close_out(idp_stub)
    with pytest.raises(Exception, match="AccessDeniedException"):
        wb.cmd_breakglass_init(ctx_factory(), BG_EMAIL)
    idp_stub.assert_no_pending_responses()
    sm_stub.assert_no_pending_responses()
    captured = capsys.readouterr()
    assert "user: DISABLED" in captured.out
    assert "break-glass credentials NOT stored" in captured.err
    assert_clean(captured, PASSWORD, SEED, CLIENT_SECRET, REFRESH)


def test_breakglass_init_preflight_missing_secret_changes_nothing(stubbed, ctx_factory, capsys):
    _, idp_stub, _, sm_stub = stubbed
    idp_stub.add_response("list_user_pool_clients", CLIENTS_PAGE, None)
    sm_stub.add_client_error("describe_secret", service_error_code="ResourceNotFoundException",
                             http_status_code=400)
    # Nothing else stubbed: any user call (ListUsers, AdminCreateUser, ...) would fail the test.
    with pytest.raises(wb.ToolError, match="preflight: cannot describe secret .*nothing was changed"):
        wb.cmd_breakglass_init(ctx_factory(), BG_EMAIL)
    idp_stub.assert_no_pending_responses()
    sm_stub.assert_no_pending_responses()


def test_breakglass_init_preflight_secret_scheduled_for_deletion(stubbed, ctx_factory):
    import datetime as dt
    _, idp_stub, _, sm_stub = stubbed
    idp_stub.add_response("list_user_pool_clients", CLIENTS_PAGE, None)
    sm_stub.add_response("describe_secret", {"Name": "aa-identity/dev/breakglass",
                                             "DeletedDate": dt.datetime(2026, 10, 18)}, None)
    with pytest.raises(wb.ToolError, match="scheduled for deletion"):
        wb.cmd_breakglass_init(ctx_factory(), BG_EMAIL)


def test_breakglass_init_listusers_miss_takes_rotation_path(stubbed, ctx_factory, monkeypatch, capsys):
    _, idp_stub, _, sm_stub = stubbed
    monkeypatch.setattr(wb, "generate_password", lambda length=wb.PASSWORD_LENGTH: PASSWORD)
    idp_stub.add_response("list_user_pool_clients", CLIENTS_PAGE, None)
    stub_describe_secret(sm_stub)
    idp_stub.add_response("list_users", {"Users": []}, None)
    idp_stub.add_client_error("admin_create_user", service_error_code="UsernameExistsException",
                              http_status_code=400)
    idp_stub.add_response("admin_add_user_to_group", {}, None)
    idp_stub.add_response("admin_add_user_to_group", {}, None)
    idp_stub.add_response("describe_user_pool_client",
                          {"UserPoolClient": {"ClientId": BG_CLIENT_ID, "ClientSecret": CLIENT_SECRET}}, None)
    idp_stub.add_response("admin_enable_user", {}, None)
    # The rotation path clears the old TOTP preference before the password sign-in.
    idp_stub.add_response("admin_set_user_mfa_preference", {}, {
        "UserPoolId": POOL, "Username": BG_EMAIL,
        "SoftwareTokenMfaSettings": {"Enabled": False, "PreferredMfa": False}})
    idp_stub.add_response("admin_set_user_password", {}, None)
    idp_stub.add_response("initiate_auth", auth_result(access_token()), None)
    idp_stub.add_response("associate_software_token", {"SecretCode": SEED}, None)
    idp_stub.add_response("verify_software_token", {"Status": "SUCCESS"}, None)
    idp_stub.add_response("admin_set_user_mfa_preference", {}, None)
    sm_stub.add_response("put_secret_value", {"VersionId": "e" * 32 + "-version"}, None)
    stub_close_out(idp_stub)
    assert wb.cmd_breakglass_init(ctx_factory(), BG_EMAIL) == 0
    idp_stub.assert_no_pending_responses()
    out = capsys.readouterr().out
    assert "already exists (not found by ListUsers)" in out
    assert "created (SUPPRESS" not in out
    assert "breakglass-init: done" in out


# --------------------------------------------------------------------------------------------
# breakglass-otp-probe (AA-816 I-C, root ADR 0006a A4)
# --------------------------------------------------------------------------------------------
BG_CLIENT_SECRET = "BG-CLIENT-SECRET-do-not-print-0123456789"


def _bg_hash(client_id):
    secret = BG_CLIENT_SECRET if client_id == BG_CLIENT_ID else CLIENT_SECRET
    return wb.secret_hash(BG_EMAIL, client_id, secret)


def _stub_probe_start(idp_stub, enabled=False, status="CONFIRMED"):
    """Client lookups, ListUsers, both client secrets, then AdminEnableUser if the user is disabled."""
    idp_stub.add_response("list_user_pool_clients", CLIENTS_PAGE, {"UserPoolId": POOL, "MaxResults": 60})
    idp_stub.add_response("list_user_pool_clients", CLIENTS_PAGE, {"UserPoolId": POOL, "MaxResults": 60})
    idp_stub.add_response("list_users", {"Users": [{"Username": USER_SUB, "UserStatus": status, "Enabled": enabled}]},
                          {"UserPoolId": POOL, "Filter": f'email = "{BG_EMAIL}"', "Limit": 2})
    idp_stub.add_response("describe_user_pool_client",
                          {"UserPoolClient": {"ClientId": BG_CLIENT_ID, "ClientSecret": BG_CLIENT_SECRET}},
                          {"UserPoolId": POOL, "ClientId": BG_CLIENT_ID})
    idp_stub.add_response("describe_user_pool_client",
                          {"UserPoolClient": {"ClientId": CIS_CLIENT_ID, "ClientSecret": CLIENT_SECRET}},
                          {"UserPoolId": POOL, "ClientId": CIS_CLIENT_ID})
    if not enabled:
        idp_stub.add_response("admin_enable_user", {}, {"UserPoolId": POOL, "Username": BG_EMAIL})


def _stub_probe_call(idp_stub, client_id, response=None, preferred=None, error=None):
    """InitiateAuth USER_AUTH with USERNAME + SECRET_HASH (+ PREFERRED_CHALLENGE) and NOTHING else.

    The exact expected params prove that no PASSWORD (or any other credential) is ever sent.
    """
    params = {"USERNAME": BG_EMAIL, "SECRET_HASH": _bg_hash(client_id)}
    if preferred:
        params["PREFERRED_CHALLENGE"] = preferred
    expected = {"AuthFlow": "USER_AUTH", "ClientId": client_id, "AuthParameters": params}
    if error:
        idp_stub.add_client_error("initiate_auth", service_error_code=error, service_message=f"{error} msg",
                                  http_status_code=400, expected_params=expected)
    else:
        idp_stub.add_response("initiate_auth", response, expected)


def _stub_restore(idp_stub, disable_fails=False):
    idp_stub.add_response("admin_user_global_sign_out", {}, {"UserPoolId": POOL, "Username": BG_EMAIL})
    if disable_fails:
        idp_stub.add_client_error("admin_disable_user", service_error_code="InternalErrorException",
                                  http_status_code=500)
    else:
        idp_stub.add_response("admin_disable_user", {}, {"UserPoolId": POOL, "Username": BG_EMAIL})


def _select(*challenges, session=S1):
    return {"ChallengeName": "SELECT_CHALLENGE", "Session": session, "ChallengeParameters": {},
            "AvailableChallenges": list(challenges)}


@pytest.fixture
def probe_ctx(stubbed, monkeypatch):
    """Ctx with NO Secrets Manager client, and RespondToAuthChallenge / AdminInitiateAuth trapped."""
    idp, _, _, _ = stubbed
    forbidden: list[str] = []

    def trap(name):
        def _call(*args, **kwargs):
            forbidden.append(name)
            raise AssertionError(f"{name} must never be called by breakglass-otp-probe")
        return _call

    for name in ("respond_to_auth_challenge", "admin_respond_to_auth_challenge", "admin_initiate_auth",
                 "admin_set_user_password"):
        monkeypatch.setattr(idp, name, trap(name))
    ctx = wb.Ctx(idp=idp, sm=None, pool_id=POOL, env="dev", out=wb.Output())
    return ctx, forbidden


def _probe_json(captured):
    return json.loads(captured.out)  # stdout is exactly one JSON document


def test_otp_probe_not_offered_exits_0_and_disables_again(stubbed, probe_ctx, capsys):
    _, idp_stub, _, _ = stubbed
    ctx, forbidden = probe_ctx
    _stub_probe_start(idp_stub)
    _stub_probe_call(idp_stub, BG_CLIENT_ID, _select("PASSWORD"))
    _stub_probe_call(idp_stub, BG_CLIENT_ID, _select("PASSWORD", session=S2), preferred="EMAIL_OTP")
    _stub_probe_call(idp_stub, CIS_CLIENT_ID, {"ChallengeName": "PASSWORD", "Session": S1, "ChallengeParameters": {}})
    _stub_probe_call(idp_stub, CIS_CLIENT_ID, preferred="EMAIL_OTP", error="InvalidParameterException")
    _stub_restore(idp_stub)
    assert wb.cmd_breakglass_otp_probe(ctx, BG_EMAIL) == 0
    idp_stub.assert_no_pending_responses()
    captured = capsys.readouterr()
    report = _probe_json(captured)
    assert report["verdict"] == "email_otp_not_offered" and report["email_otp_offered"] is False
    assert report["enabled_at_start"] is False and report["restored"] is True
    bg, cis = report["clients"]
    assert bg["client"] == "aa-workforce-dev-breakglass" and bg["email_otp_offered"] is False
    assert bg["no_preference"] == {"challenge": "SELECT_CHALLENGE", "available_challenges": ["PASSWORD"],
                                   "error": None, "tokens_issued": False}
    assert cis["client"] == "aa-workforce-dev-cis-admin" and cis["no_preference"]["challenge"] == "PASSWORD"
    assert cis["prefer_email_otp"]["error"] == "InvalidParameterException"
    assert "user: DISABLED" in captured.err and "breakglass-otp-probe: OK" in captured.err
    assert forbidden == []
    assert_clean(captured, S1, S2, BG_CLIENT_SECRET, CLIENT_SECRET)


def test_otp_probe_email_otp_offered_is_a_finding_exit_1(stubbed, probe_ctx, capsys):
    _, idp_stub, _, _ = stubbed
    ctx, forbidden = probe_ctx
    _stub_probe_start(idp_stub)
    # breakglass lists EMAIL_OTP already: the preferred call is skipped (no extra code e-mail).
    _stub_probe_call(idp_stub, BG_CLIENT_ID, _select("EMAIL_OTP", "PASSWORD"))
    _stub_probe_call(idp_stub, CIS_CLIENT_ID, _select("PASSWORD"))
    _stub_probe_call(idp_stub, CIS_CLIENT_ID, {
        "ChallengeName": "EMAIL_OTP", "Session": S2,
        "ChallengeParameters": {"CODE_DELIVERY_DESTINATION": "a***@a***", "CODE_DELIVERY_DELIVERY_MEDIUM": "EMAIL"},
    }, preferred="EMAIL_OTP")
    _stub_restore(idp_stub)
    assert wb.cmd_breakglass_otp_probe(ctx, BG_EMAIL) == 1
    idp_stub.assert_no_pending_responses()
    captured = capsys.readouterr()
    report = _probe_json(captured)
    assert report["verdict"] == "email_otp_offered" and report["email_otp_offered"] is True
    bg, cis = report["clients"]
    assert bg["email_otp_offered"] is True and "skipped" in bg["prefer_email_otp"]
    assert cis["email_otp_offered"] is True and cis["prefer_email_otp"]["challenge"] == "EMAIL_OTP"
    assert "FINDING EMAIL_OTP is offered" in captured.err
    assert "CODE_DELIVERY" not in captured.out
    assert forbidden == []
    assert_clean(captured, S1, S2, BG_CLIENT_SECRET, CLIENT_SECRET)


def test_otp_probe_error_still_disables_and_reraises(stubbed, probe_ctx, capsys):
    _, idp_stub, _, _ = stubbed
    ctx, _ = probe_ctx
    idp_stub.add_response("list_user_pool_clients", CLIENTS_PAGE, None)
    idp_stub.add_response("list_user_pool_clients", CLIENTS_PAGE, None)
    idp_stub.add_response("list_users", {"Users": [{"Username": USER_SUB, "Enabled": False}]}, None)
    idp_stub.add_response("describe_user_pool_client",
                          {"UserPoolClient": {"ClientId": BG_CLIENT_ID, "ClientSecret": BG_CLIENT_SECRET}}, None)
    idp_stub.add_response("describe_user_pool_client",
                          {"UserPoolClient": {"ClientId": CIS_CLIENT_ID, "ClientSecret": CLIENT_SECRET}}, None)
    idp_stub.add_client_error("admin_enable_user", service_error_code="InternalErrorException", http_status_code=500)
    _stub_restore(idp_stub)
    with pytest.raises(Exception, match="InternalErrorException"):
        wb.cmd_breakglass_otp_probe(ctx, BG_EMAIL)
    idp_stub.assert_no_pending_responses()
    captured = capsys.readouterr()
    report = _probe_json(captured)
    assert report["verdict"] == "inconclusive" and report["restored"] is True
    assert "user: DISABLED" in captured.err


def test_otp_probe_initiate_auth_error_is_inconclusive_and_disables(stubbed, probe_ctx, capsys):
    _, idp_stub, _, _ = stubbed
    ctx, _ = probe_ctx
    _stub_probe_start(idp_stub)
    _stub_probe_call(idp_stub, BG_CLIENT_ID, error="NotAuthorizedException")
    _stub_probe_call(idp_stub, BG_CLIENT_ID, preferred="EMAIL_OTP", error="NotAuthorizedException")
    _stub_probe_call(idp_stub, CIS_CLIENT_ID, _select("PASSWORD"))
    _stub_probe_call(idp_stub, CIS_CLIENT_ID, _select("PASSWORD", session=S2), preferred="EMAIL_OTP")
    _stub_restore(idp_stub)
    assert wb.cmd_breakglass_otp_probe(ctx, BG_EMAIL) == 1
    idp_stub.assert_no_pending_responses()
    captured = capsys.readouterr()
    report = _probe_json(captured)
    assert report["verdict"] == "inconclusive"
    assert report["clients"][0]["no_preference"]["error"] == "NotAuthorizedException"
    assert "INCONCLUSIVE" in captured.err and "user: DISABLED" in captured.err


def test_otp_probe_user_enabled_at_start_is_left_enabled(stubbed, probe_ctx, capsys):
    _, idp_stub, _, _ = stubbed
    ctx, _ = probe_ctx
    _stub_probe_start(idp_stub, enabled=True)
    _stub_probe_call(idp_stub, BG_CLIENT_ID, _select("PASSWORD"))
    _stub_probe_call(idp_stub, BG_CLIENT_ID, _select("PASSWORD", session=S2), preferred="EMAIL_OTP")
    _stub_probe_call(idp_stub, CIS_CLIENT_ID, _select("PASSWORD"))
    _stub_probe_call(idp_stub, CIS_CLIENT_ID, _select("PASSWORD", session=S2), preferred="EMAIL_OTP")
    # No admin_enable_user, admin_user_global_sign_out or admin_disable_user stubbed: any call fails.
    assert wb.cmd_breakglass_otp_probe(ctx, BG_EMAIL) == 0
    idp_stub.assert_no_pending_responses()
    captured = capsys.readouterr()
    report = _probe_json(captured)
    assert report["enabled_at_start"] is True and report["restored"] is True
    assert "already ENABLED" in captured.err and "user: DISABLED" not in captured.err


def test_otp_probe_unknown_user_changes_nothing(stubbed, probe_ctx):
    _, idp_stub, _, _ = stubbed
    ctx, _ = probe_ctx
    idp_stub.add_response("list_user_pool_clients", CLIENTS_PAGE, None)
    idp_stub.add_response("list_user_pool_clients", CLIENTS_PAGE, None)
    idp_stub.add_response("list_users", {"Users": []}, None)
    with pytest.raises(wb.ToolError, match="nothing was changed"):
        wb.cmd_breakglass_otp_probe(ctx, BG_EMAIL)
    idp_stub.assert_no_pending_responses()


def test_otp_probe_refuses_out_of_domain_before_any_call(stubbed, probe_ctx):
    ctx, _ = probe_ctx
    with pytest.raises(wb.ToolError, match="outside the staff domain"):
        wb.cmd_breakglass_otp_probe(ctx, "admin@example.com")


class _FakeSts:
    def get_caller_identity(self):
        return {"Account": wb.DEFAULT_ACCOUNT}


class _FakeSession:
    """boto3.Session stand-in: records every client the tool creates."""

    created: list[str] = []
    idp = None

    def __init__(self, profile_name=None, region_name=None):
        self._session = None  # the assume-role cache hook is best effort and skipped

    def client(self, name):
        _FakeSession.created.append(name)
        if name == "sts":
            return _FakeSts()
        if name == "cognito-idp":
            return _FakeSession.idp
        raise AssertionError(f"unexpected client {name}")


def test_otp_probe_main_creates_no_secretsmanager_client_and_cleanup_failure_exits_2(stubbed, monkeypatch, capsys):
    import boto3

    idp, idp_stub, _, sm_stub = stubbed
    _FakeSession.created = []
    _FakeSession.idp = idp
    monkeypatch.setattr(boto3, "Session", _FakeSession)
    monkeypatch.setattr(idp, "respond_to_auth_challenge",
                        lambda *a, **k: (_ for _ in ()).throw(AssertionError("RespondToAuthChallenge called")))
    _stub_probe_start(idp_stub)
    _stub_probe_call(idp_stub, BG_CLIENT_ID, _select("PASSWORD"))
    _stub_probe_call(idp_stub, BG_CLIENT_ID, _select("PASSWORD", session=S2), preferred="EMAIL_OTP")
    _stub_probe_call(idp_stub, CIS_CLIENT_ID, _select("PASSWORD"))
    _stub_probe_call(idp_stub, CIS_CLIENT_ID, _select("PASSWORD", session=S2), preferred="EMAIL_OTP")
    _stub_restore(idp_stub, disable_fails=True)
    rc = wb.main(["--pool-id", POOL, "breakglass-otp-probe"])
    assert rc == 2
    idp_stub.assert_no_pending_responses()
    sm_stub.assert_no_pending_responses()
    assert "secretsmanager" not in _FakeSession.created
    assert _FakeSession.created == ["sts", "cognito-idp"]
    captured = capsys.readouterr()
    report = _probe_json(captured)  # the account preamble went to stderr, stdout is still pure JSON
    assert report["restored"] is False
    assert report["cleanup_failures"] == ["admin_disable_user InternalErrorException"]
    assert "breakglass-otp-probe: cleanup INCOMPLETE (admin_disable_user InternalErrorException)" in captured.err
    assert "admin-disable-user" in captured.err and "aws: account" in captured.err
    assert "breakglass-otp-probe: OK" not in captured.err
    assert_clean(captured, S1, S2, BG_CLIENT_SECRET, CLIENT_SECRET)


def test_main_still_creates_secretsmanager_client_for_breakglass_verify(monkeypatch):
    import boto3

    def client(self, name):
        _FakeSession.created.append(name)
        return _FakeSts() if name == "sts" else object()

    _FakeSession.created = []
    monkeypatch.setattr(boto3, "Session", _FakeSession)
    monkeypatch.setattr(_FakeSession, "client", client)
    args = wb.build_parser().parse_args(["breakglass-verify"])
    _, sm = wb._aws_clients(args, wb.Output(out=lambda s: None, err=lambda s: None))
    assert sm is not None and _FakeSession.created == ["sts", "cognito-idp", "secretsmanager"]
