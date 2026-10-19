#!/usr/bin/env python3
"""WORKFORCE pool bootstrap tool (AA-854, root ADR 0006 decisions 3 and 11, Phase 1 step I2).

Run by an AWS admin (Nghiep) with MFA, from a workstation. Not run by CI, not deployed.
Uses the Python standard library and boto3 only (TOTP is RFC 6238 on hmac, no pyotp).

Subcommands
  create-staff --email E --groups G[,G]   AdminCreateUser (MessageAction=SUPPRESS, email_verified=true)
                                          + AdminAddUserToGroup. Never sets a password.
  breakglass-init                         Create or rotate the break-glass user: random permanent
                                          password, TOTP enrolled, stored in aa-identity/dev/breakglass,
                                          then tokens revoked and the user DISABLED (always, finally).
  breakglass-verify                       Enable, sign in with password + TOTP on the breakglass client,
                                          print the claim summary, revoke, sign out, DISABLE (finally).
  breakglass-otp-probe                    ADR 0006a A4 check (AA-816): enable if disabled, ask the
                                          breakglass + cis-admin clients for first factors with
                                          InitiateAuth USER_AUTH + USERNAME only (never a password, never
                                          an answer, never the secret), print JSON, then restore the
                                          Enabled state (finally). Exit 0 no EMAIL_OTP, 1 finding or
                                          inconclusive, 2 cleanup incomplete.
  authorize-url --client C --redirect R   Spike helper: managed-login authorize URL with PKCE S256;
                                          verifier + state go to a 0600 file under
                                          .tmp-session/identity-spike/ (or --state-dir).
  exchange-code [--url CALLBACK_URL]      Spike helper: check state, exchange the code (client secret
                                          read with DescribeUserPoolClient), print non-secret claims of
                                          the access + ID tokens, then revoke the refresh token.

Fail closed: if a cleanup step (revoke, global sign-out, disable) fails, the command exits 1 and does
not print "done"/"OK", even when the main work succeeded (breakglass-otp-probe exits 2 instead, so a
script can tell "user may still be enabled" apart from a finding).

Secret hygiene: passwords, TOTP seeds, client secrets, codes and tokens are never printed. Every line
goes through a redactor that masks any registered secret, and errors are printed without a traceback.

Signing in as break-glass raises the alarm aa-identity-dev-breakglass-token-issued by design (ADR 0006
decision 11), and reading or writing the secret raises the CloudTrail alert (I1): both are expected.
"""

from __future__ import annotations

import argparse
import base64
import getpass
import hashlib
import hmac
import json
import os
import re
import secrets
import string
import struct
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Iterable

# --------------------------------------------------------------------------------------------
# Dev facts (plan §6; accounts/aa365/identity.tf). Each one has a command-line override.
# --------------------------------------------------------------------------------------------
DEFAULT_PROFILE = "aa365-admin"
DEFAULT_REGION = "us-west-1"
DEFAULT_ACCOUNT = "005097885195"
DEFAULT_POOL_ID = "us-west-1_bCcFvbSOS"
DEFAULT_ENV = "dev"
DEFAULT_HOSTED_DOMAIN = "https://aa365-staff-auth-dev.auth.us-west-1.amazoncognito.com"
# D1 (S241/S242): break-glass stays admin@adventure.asia = identity_breakglass_email default.
DEFAULT_BREAKGLASS_EMAIL = "admin@adventure.asia"
STAFF_EMAIL_DOMAIN = "adventure.asia"
# Local part allowed in addresses the tool handles. It also keeps the ListUsers filter
# (email = "...") free of quotes and backslashes.
EMAIL_LOCAL_RE = re.compile(r"^[a-z0-9._%+-]+$")
STATE_DIR_NAME = "identity-spike"  # <AA-Ecosys>/.tmp-session/identity-spike (gitignored)
# identity.tf local.id_staff_groups (same list as the trigger's DEFAULT_STAFF_GROUPS).
STAFF_GROUPS = (
    "cis-admin",
    "cis-reviewer",
    "cis-content",
    "booking-admin",
    "booking-sales",
    "booking-contracting",
    "booking-content_creator",
)
BREAKGLASS_GROUPS = ("cis-admin", "booking-admin")  # ADR 0006 decision 11
# breakglass-otp-probe asks these app clients (aa-workforce-<env>-<name>) for first factors: the
# break-glass client, and cis-admin, whose managed login is the one a mailbox holder would use.
OTP_PROBE_CLIENTS = ("breakglass", "cis-admin")
# Commands that must never create a Secrets Manager client (the break-glass secret stays unread).
NO_SECRETS_MANAGER_COMMANDS = ("breakglass-otp-probe",)
OAUTH_SCOPES = "openid email profile"
TOTP_STEP = 30
TOTP_DIGITS = 6
PASSWORD_LENGTH = 32
PASSWORD_SYMBOLS = "!@#%^*-_=+.?"  # subset of Cognito's allowed symbols, shell- and JSON-safe

# Claims that are safe to print. Everything else (jti, origin_jti, at_hash, tokens) is dropped.
SAFE_CLAIMS = (
    "iss",
    "token_use",
    "client_id",
    "aud",
    "sub",
    "cognito:username",
    "cognito:groups",
    "email",
    "email_verified",
    "name",
    "scope",
    "auth_time",
    "iat",
    "exp",
)


class ToolError(Exception):
    """Expected failure: printed as one line, exit code 1."""

    exit_code = 1


class CleanupIncomplete(ToolError):
    """breakglass-otp-probe could not put the user back to disabled: exit code 2 (fail closed)."""

    exit_code = 2


# --------------------------------------------------------------------------------------------
# Output with redaction. Every print goes through Output so a registered secret never leaves.
# --------------------------------------------------------------------------------------------
@dataclass
class Output:
    out: Callable[[str], None] = field(default=lambda s: print(s, flush=True))
    err: Callable[[str], None] = field(default=lambda s: print(s, file=sys.stderr, flush=True))
    _secrets: set = field(default_factory=set)

    def register(self, *values: str | None) -> None:
        for value in values:
            if value and len(value) >= 4:
                self._secrets.add(value)

    def redact(self, text: str) -> str:
        for value in sorted(self._secrets, key=len, reverse=True):
            text = text.replace(value, "***")
        return text

    def info(self, text: str) -> None:
        self.out(self.redact(text))

    def warn(self, text: str) -> None:
        self.err(self.redact(text))


# --------------------------------------------------------------------------------------------
# TOTP (RFC 6238 over RFC 4226 HOTP), stdlib only.
# --------------------------------------------------------------------------------------------
def b32decode_seed(seed: str) -> bytes:
    cleaned = seed.strip().replace(" ", "").upper()
    cleaned += "=" * (-len(cleaned) % 8)
    return base64.b32decode(cleaned)


def hotp(key: bytes, counter: int, digits: int = TOTP_DIGITS, digest=hashlib.sha1) -> str:
    mac = hmac.new(key, struct.pack(">Q", counter), digest).digest()
    offset = mac[-1] & 0x0F
    code = (struct.unpack(">I", mac[offset : offset + 4])[0] & 0x7FFFFFFF) % (10**digits)
    return str(code).zfill(digits)


def totp(key: bytes, at: float, digits: int = TOTP_DIGITS, step: int = TOTP_STEP, digest=hashlib.sha1) -> str:
    return hotp(key, int(at // step), digits=digits, digest=digest)


def wait_for_fresh_window(
    clock: Callable[[], float], sleep: Callable[[float], None], step: int = TOTP_STEP
) -> float:
    """Sleep to just after the next TOTP step boundary and return that time.

    Cognito refuses a code that was already used. A code from a step that started before this call
    may have been used by an earlier run (breakglass-init verifies one), so always start a new step.
    """
    now = clock()
    boundary = (int(now // step) + 1) * step
    sleep(boundary - now + 1.0)
    return clock()


# --------------------------------------------------------------------------------------------
# Small pure helpers
# --------------------------------------------------------------------------------------------
def normalise_email(email: str) -> str:
    return (email or "").strip().lower()


def split_email(email: str) -> tuple[str, str]:
    """Normalise and split; refuse a missing part or an unsupported character in the local part."""
    email = normalise_email(email)
    local, sep, domain = email.rpartition("@")
    if not sep or not local or not domain:
        raise ToolError("refused client-side: not an email address")
    if not EMAIL_LOCAL_RE.match(local):
        raise ToolError("refused client-side: unsupported character in the email local part "
                        "(allowed: a-z 0-9 . _ % + -)")
    return local, domain


def require_staff_email(email: str) -> str:
    email = normalise_email(email)
    local, sep, domain = email.rpartition("@")
    if not sep or not local or domain != STAFF_EMAIL_DOMAIN:
        # Worded differently from the trigger's server-side reason (workforce.py) on purpose, so A5
        # evidence cannot mix up a client-side refusal with the pre sign-up trigger's.
        raise ToolError(f"refused client-side: address outside the staff domain (@{STAFF_EMAIL_DOMAIN} only)")
    split_email(email)
    return email


def parse_groups(raw: str) -> list[str]:
    groups = [g.strip() for g in (raw or "").split(",") if g.strip()]
    if not groups:
        raise ToolError("refused: at least one staff group is required (the pre token trigger denies a user in none)")
    unknown = sorted(set(groups) - set(STAFF_GROUPS))
    if unknown:
        raise ToolError(f"refused: unknown group(s) {unknown}; allowed: {list(STAFF_GROUPS)}")
    return list(dict.fromkeys(groups))


def secret_hash(username: str, client_id: str, client_secret: str) -> str:
    mac = hmac.new(client_secret.encode(), (username + client_id).encode(), hashlib.sha256).digest()
    return base64.b64encode(mac).decode()


def generate_password(length: int = PASSWORD_LENGTH) -> str:
    """Random password meeting the WORKFORCE policy (>= 16, upper, lower, digit, symbol)."""
    alphabet = string.ascii_letters + string.digits + PASSWORD_SYMBOLS
    while True:
        pw = "".join(secrets.choice(alphabet) for _ in range(length))
        if (
            any(c.islower() for c in pw)
            and any(c.isupper() for c in pw)
            and any(c.isdigit() for c in pw)
            and any(c in PASSWORD_SYMBOLS for c in pw)
        ):
            return pw


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def pkce_pair() -> tuple[str, str]:
    verifier = b64url(secrets.token_bytes(32))
    challenge = b64url(hashlib.sha256(verifier.encode()).digest())
    return verifier, challenge


def jwt_claims(token: str) -> dict:
    """Decode a JWT payload WITHOUT verifying it (display only; it came straight from Cognito)."""
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        return json.loads(base64.urlsafe_b64decode(payload))
    except Exception as exc:  # noqa: BLE001
        raise ToolError(f"could not decode token payload ({type(exc).__name__})") from None


def claim_summary(label: str, token: str) -> list[str]:
    claims = jwt_claims(token)
    lines = [f"{label}:"]
    for name in SAFE_CLAIMS:
        if name in claims:
            lines.append(f"  {name} = {json.dumps(claims[name])}")
    if "exp" in claims and "iat" in claims:
        lines.append(f"  lifetime_s = {int(claims['exp']) - int(claims['iat'])}")
    return lines


def find_state_dir(start: Path) -> Path:
    """<AA-Ecosys root>/.tmp-session/identity-spike, found by walking up to the folder holding .tmp-session."""
    for parent in [start, *start.parents]:
        if (parent / ".tmp-session").is_dir() and parent.name != ".tmp-session":
            return parent / ".tmp-session" / STATE_DIR_NAME
    raise ToolError("could not find the workspace .tmp-session folder; pass --state-dir")


def write_private_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        json.dump(data, fh)
    os.chmod(path, 0o600)  # O_CREAT mode does not apply to an existing file


# --------------------------------------------------------------------------------------------
# Cognito helpers (clients are injected so tests can use botocore Stubber)
# --------------------------------------------------------------------------------------------
def find_client_id(idp, pool_id: str, client_name: str) -> str:
    kwargs = {"UserPoolId": pool_id, "MaxResults": 60}
    while True:
        page = idp.list_user_pool_clients(**kwargs)
        for client in page.get("UserPoolClients", []):
            if client.get("ClientName") == client_name:
                return client["ClientId"]
        token = page.get("NextToken")
        if not token:
            raise ToolError(f"app client {client_name!r} not found in pool {pool_id}")
        kwargs["NextToken"] = token


def client_secret_of(idp, pool_id: str, client_id: str, out: Output) -> str:
    desc = idp.describe_user_pool_client(UserPoolId=pool_id, ClientId=client_id)
    secret = (desc.get("UserPoolClient") or {}).get("ClientSecret")
    if not secret:
        raise ToolError(f"client {client_id} has no secret (expected a confidential client)")
    out.register(secret)
    return secret


def find_user(idp, pool_id: str, email: str) -> dict | None:
    """ListUsers by email (does not count as MAU, unlike AdminGetUser; ADR 0006)."""
    page = idp.list_users(UserPoolId=pool_id, Filter=f'email = "{email}"', Limit=2)
    users = page.get("Users", [])
    if len(users) > 1:
        raise ToolError(f"more than one user has email {email}; fix the pool by hand")
    return users[0] if users else None


def create_user_suppressed(idp, pool_id: str, email: str, name: str | None = None) -> bool:
    """AdminCreateUser with MessageAction=SUPPRESS + email_verified=true. Returns False if it existed.

    SUPPRESS is mandatory (identity.tf header): without it Cognito mails the temporary password and the
    person could set a permanent password through managed login, bypassing email-code-only sign-in.
    """
    attrs = [{"Name": "email", "Value": email}, {"Name": "email_verified", "Value": "true"}]
    if name:
        attrs.append({"Name": "name", "Value": name})
    try:
        idp.admin_create_user(
            UserPoolId=pool_id,
            Username=email,
            UserAttributes=attrs,
            MessageAction="SUPPRESS",
        )
        return True
    except idp.exceptions.UsernameExistsException:
        return False


def add_to_groups(idp, pool_id: str, username: str, groups: Iterable[str], out: Output) -> None:
    for group in groups:
        idp.admin_add_user_to_group(UserPoolId=pool_id, Username=username, GroupName=group)
        out.info(f"group: {group} ok")


@dataclass
class SignInResult:
    access_token: str
    refresh_token: str | None


def sign_in(
    idp,
    *,
    client_id: str,
    client_secret: str,
    username: str,
    password: str,
    totp_seed: str | None,
    clock: Callable[[], float],
    sleep: Callable[[float], None],
    out: Output,
) -> SignInResult:
    """USER_AUTH sign-in with a password, answering SELECT_CHALLENGE / PASSWORD / SOFTWARE_TOKEN_MFA."""
    user = username
    resp = idp.initiate_auth(
        AuthFlow="USER_AUTH",
        ClientId=client_id,
        AuthParameters={
            "USERNAME": user,
            "PREFERRED_CHALLENGE": "PASSWORD",
            "PASSWORD": password,
            "SECRET_HASH": secret_hash(user, client_id, client_secret),
        },
    )
    for _ in range(5):
        result = resp.get("AuthenticationResult")
        if result:
            out.register(result.get("AccessToken"), result.get("IdToken"), result.get("RefreshToken"))
            return SignInResult(result["AccessToken"], result.get("RefreshToken"))
        challenge = resp.get("ChallengeName")
        params = resp.get("ChallengeParameters") or {}
        # With email as the username attribute, later SECRET_HASHes use the internal user name.
        user = params.get("USERNAME") or params.get("USER_ID_FOR_SRP") or user
        base = {"USERNAME": user, "SECRET_HASH": secret_hash(user, client_id, client_secret)}
        if challenge == "SELECT_CHALLENGE":
            answers = {**base, "ANSWER": "PASSWORD", "PASSWORD": password}
        elif challenge == "PASSWORD":
            answers = {**base, "PASSWORD": password}
        elif challenge == "SOFTWARE_TOKEN_MFA":
            if not totp_seed:
                raise ToolError("Cognito asked for TOTP but no seed is available")
            at = wait_for_fresh_window(clock, sleep)
            code = totp(b32decode_seed(totp_seed), at)
            out.register(code)
            answers = {**base, "SOFTWARE_TOKEN_MFA_CODE": code}
            out.info("sign-in: answering SOFTWARE_TOKEN_MFA with a fresh TOTP window")
        else:
            raise ToolError(f"unexpected challenge {challenge!r}; stopping (user will be disabled)")
        out.info(f"sign-in: challenge {challenge} answered")
        resp = idp.respond_to_auth_challenge(
            ClientId=client_id, ChallengeName=challenge, ChallengeResponses=answers, Session=resp.get("Session")
        )
    raise ToolError("too many challenges; stopping")


def close_out(idp, *, pool_id: str, username: str, client_id: str | None, client_secret: str | None,
              refresh_token: str | None, out: Output) -> list[str]:
    """Revoke, global sign-out, disable. Each step runs even if an earlier one failed."""
    failures = []
    if refresh_token and client_id:
        try:
            kwargs = {"Token": refresh_token, "ClientId": client_id}
            if client_secret:
                kwargs["ClientSecret"] = client_secret
            idp.revoke_token(**kwargs)
            out.info("revoke: refresh token revoked")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"revoke_token {type(exc).__name__}")
    try:
        idp.admin_user_global_sign_out(UserPoolId=pool_id, Username=username)
        out.info("sign-out: global sign-out done")
    except Exception as exc:  # noqa: BLE001
        failures.append(f"admin_user_global_sign_out {type(exc).__name__}")
    try:
        idp.admin_disable_user(UserPoolId=pool_id, Username=username)
        out.info("user: DISABLED")
    except Exception as exc:  # noqa: BLE001
        failures.append(f"admin_disable_user {type(exc).__name__}")
    for failure in failures:
        out.warn(f"WARNING cleanup step failed: {failure}. Disable the user by hand: "
                 f"aws cognito-idp admin-disable-user --user-pool-id {pool_id} --username {username}")
    return failures


# --------------------------------------------------------------------------------------------
# Context
# --------------------------------------------------------------------------------------------
@dataclass
class Ctx:
    idp: object
    sm: object | None
    pool_id: str
    env: str
    out: Output
    clock: Callable[[], float] = time.time
    sleep: Callable[[float], None] = time.sleep
    http_post: Callable[..., dict] | None = None

    @property
    def breakglass_client_name(self) -> str:
        return f"aa-workforce-{self.env}-breakglass"

    @property
    def secret_id(self) -> str:
        return f"aa-identity/{self.env}/breakglass"


# --------------------------------------------------------------------------------------------
# Subcommands
# --------------------------------------------------------------------------------------------
def cleanup_failed_error(cmd: str, failures: list[str], pool_id: str, username: str, note: str = "") -> ToolError:
    """Fail closed: a failed revoke / sign-out / disable makes the whole command fail (exit 1)."""
    return ToolError(
        f"{cmd}: cleanup INCOMPLETE ({', '.join(failures)}).{note} The user may still be enabled: run "
        f"aws cognito-idp admin-disable-user --user-pool-id {pool_id} --username {username} "
        f"--profile aa365-admin --region us-west-1"
    )


def cmd_create_staff(ctx: Ctx, email: str, groups_raw: str, name: str | None,
                     breakglass_email: str, trigger_refusal_test: bool = False) -> int:
    groups = parse_groups(groups_raw)
    if trigger_refusal_test:
        return _trigger_refusal_test(ctx, email)
    email = require_staff_email(email)
    if email == normalise_email(breakglass_email):
        raise ToolError("refused: that is the break-glass address; use breakglass-init")
    created = create_user_suppressed(ctx.idp, ctx.pool_id, email, name)
    ctx.out.info(f"user: {email} {'created (SUPPRESS, email_verified=true, no password)' if created else 'already exists'}")
    add_to_groups(ctx.idp, ctx.pool_id, email, groups, ctx.out)
    ctx.out.info("create-staff: done (sign-in is by email code through managed login)")
    return 0


def _trigger_refusal_test(ctx: Ctx, email: str) -> int:
    """A5 evidence: AdminCreateUser an out-of-domain address and expect the pre sign-up trigger to refuse.

    Never adds groups. If Cognito accepts the user (trigger NOT refusing), the user is disabled at once
    and the command fails, so no out-of-domain account is left usable.
    """
    _, domain = split_email(email)
    email = normalise_email(email)
    if domain == STAFF_EMAIL_DOMAIN:
        raise ToolError("refused: --trigger-refusal-test needs an address OUTSIDE the staff domain")
    ctx.out.warn("WARNING --trigger-refusal-test: client-side domain check skipped; no groups will be added")
    try:
        create_user_suppressed(ctx.idp, ctx.pool_id, email)
    except ctx.idp.exceptions.UserLambdaValidationException as exc:
        message = (getattr(exc, "response", {}).get("Error") or {}).get("Message", "")
        ctx.out.info(f"trigger: refused server-side (UserLambdaValidationException): {message}")
        ctx.out.info("create-staff --trigger-refusal-test: OK (pre sign-up trigger refused the address)")
        return 0
    try:
        ctx.idp.admin_disable_user(UserPoolId=ctx.pool_id, Username=email)
        disabled = "the user was created and then DISABLED"
    except Exception as exc:  # noqa: BLE001
        disabled = f"the user was created and disabling it FAILED ({type(exc).__name__})"
    raise ToolError(
        f"trigger did NOT refuse {email}: {disabled}. Remove it by hand: aws cognito-idp admin-delete-user "
        f"--user-pool-id {ctx.pool_id} --username {email} --profile aa365-admin --region us-west-1"
    )


def cmd_breakglass_init(ctx: Ctx, email: str) -> int:
    email = require_staff_email(email)
    client_id = find_client_id(ctx.idp, ctx.pool_id, ctx.breakglass_client_name)
    ctx.out.info(f"client: {ctx.breakglass_client_name} = {client_id}")
    # Preflight before touching the user: a missing or deleted secret fails here, not after the old
    # password is gone. DescribeSecret is metadata only (no value; not one of the I1 alert events).
    try:
        described = ctx.sm.describe_secret(SecretId=ctx.secret_id)
    except Exception as exc:  # noqa: BLE001
        raise ToolError(f"preflight: cannot describe secret {ctx.secret_id} ({type(exc).__name__}); "
                        "nothing was changed") from None
    if described.get("DeletedDate"):
        raise ToolError(f"preflight: secret {ctx.secret_id} is scheduled for deletion; nothing was changed")
    ctx.out.info(f"preflight: secret {ctx.secret_id} exists")
    existing = find_user(ctx.idp, ctx.pool_id, email)
    if existing is None:
        if create_user_suppressed(ctx.idp, ctx.pool_id, email):
            ctx.out.info(f"user: {email} created (SUPPRESS, email_verified=true)")
        else:
            # ListUsers missed a user that exists (filter mismatch or race): treat it as a rotation.
            existing = {"UserStatus": "unknown"}
            ctx.out.info(f"user: {email} already exists (not found by ListUsers); rotating password + TOTP")
    else:
        ctx.out.info(f"user: {email} exists (status {existing.get('UserStatus')}); rotating password + TOTP")
    username = email
    client_secret = None
    signed_in = None
    password_set = False
    stored = False
    failures: list[str] = []
    try:
        add_to_groups(ctx.idp, ctx.pool_id, username, BREAKGLASS_GROUPS, ctx.out)
        client_secret = client_secret_of(ctx.idp, ctx.pool_id, client_id, ctx.out)
        ctx.idp.admin_enable_user(UserPoolId=ctx.pool_id, Username=username)
        ctx.out.info("user: enabled for enrolment")
        if existing is not None:
            # Rotation: drop the old TOTP preference so the password sign-in below is not challenged
            # for the old seed (the tool never reads the old secret value). A new seed follows.
            try:
                ctx.idp.admin_set_user_mfa_preference(
                    UserPoolId=ctx.pool_id, Username=username,
                    SoftwareTokenMfaSettings={"Enabled": False, "PreferredMfa": False},
                )
                ctx.out.info("mfa: old TOTP preference cleared for rotation")
            except ctx.idp.exceptions.InvalidParameterException:
                # An earlier run stopped before TOTP was enrolled: nothing to clear.
                ctx.out.info("mfa: no TOTP enrolled yet, nothing to clear")
        password = generate_password()
        ctx.out.register(password)
        ctx.idp.admin_set_user_password(UserPoolId=ctx.pool_id, Username=username, Password=password, Permanent=True)
        password_set = True
        ctx.out.info("password: new permanent password set")

        signed_in = sign_in(
            ctx.idp, client_id=client_id, client_secret=client_secret, username=username,
            password=password, totp_seed=None, clock=ctx.clock, sleep=ctx.sleep, out=ctx.out,
        )
        ctx.out.info("sign-in: password sign-in ok (break-glass alarm will fire, expected)")

        assoc = ctx.idp.associate_software_token(AccessToken=signed_in.access_token)
        seed = assoc["SecretCode"]
        ctx.out.register(seed)
        code = totp(b32decode_seed(seed), ctx.clock())
        ctx.out.register(code)
        verified = ctx.idp.verify_software_token(
            AccessToken=signed_in.access_token, UserCode=code, FriendlyDeviceName="breakglass"
        )
        if verified.get("Status") != "SUCCESS":
            raise ToolError(f"VerifySoftwareToken status {verified.get('Status')}")
        ctx.idp.admin_set_user_mfa_preference(
            UserPoolId=ctx.pool_id, Username=username,
            SoftwareTokenMfaSettings={"Enabled": True, "PreferredMfa": True},
        )
        ctx.out.info("mfa: TOTP enrolled, verified and preferred")

        value = json.dumps({
            "username": username,
            "password": password,
            "totp_seed": seed,
            "created_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        })
        put = ctx.sm.put_secret_value(SecretId=ctx.secret_id, SecretString=value)
        stored = True
        ctx.out.info(f"secret: {ctx.secret_id} stored, VersionId {put.get('VersionId')}")
    finally:
        failures = close_out(ctx.idp, pool_id=ctx.pool_id, username=username, client_id=client_id,
                             client_secret=client_secret,
                             refresh_token=signed_in.refresh_token if signed_in else None, out=ctx.out)
        if password_set and not stored:
            ctx.out.warn("WARNING break-glass credentials NOT stored: the previous password (and any old "
                         f"secret value in {ctx.secret_id}) is now invalid. Re-run breakglass-init.")
    if failures:
        raise cleanup_failed_error("breakglass-init", failures, ctx.pool_id, username,
                                   note=f" The new credentials WERE stored in {ctx.secret_id}.")
    ctx.out.info("breakglass-init: done. Next: breakglass-verify (waits for a fresh TOTP window)")
    return 0


def cmd_breakglass_verify(ctx: Ctx, email: str) -> int:
    email = require_staff_email(email)
    client_id = find_client_id(ctx.idp, ctx.pool_id, ctx.breakglass_client_name)
    ctx.out.info(f"client: {ctx.breakglass_client_name} = {client_id}")
    raw = ctx.sm.get_secret_value(SecretId=ctx.secret_id)
    ctx.out.info(f"secret: read {ctx.secret_id} VersionId {raw.get('VersionId')} (secret alert will fire, expected)")
    try:
        stored = json.loads(raw["SecretString"])
    except (KeyError, ValueError):
        raise ToolError("secret value is not the expected JSON; run breakglass-init") from None
    password, seed = stored.get("password"), stored.get("totp_seed")
    ctx.out.register(password, seed)
    username = normalise_email(stored.get("username") or email)
    if username != email:
        raise ToolError(f"secret holds user {username}, expected {email}")
    if not password or not seed:
        raise ToolError("secret value lacks password or totp_seed; run breakglass-init")
    client_secret = None
    signed_in = None
    failures: list[str] = []
    try:
        client_secret = client_secret_of(ctx.idp, ctx.pool_id, client_id, ctx.out)
        ctx.idp.admin_enable_user(UserPoolId=ctx.pool_id, Username=username)
        ctx.out.info("user: enabled for the test")
        signed_in = sign_in(
            ctx.idp, client_id=client_id, client_secret=client_secret, username=username,
            password=password, totp_seed=seed, clock=ctx.clock, sleep=ctx.sleep, out=ctx.out,
        )
        for line in claim_summary("access token claims", signed_in.access_token):
            ctx.out.info(line)
        claims = jwt_claims(signed_in.access_token)
        if claims.get("token_use") != "access" or claims.get("client_id") != client_id:
            raise ToolError("unexpected access token (token_use/client_id)")
    finally:
        failures = close_out(ctx.idp, pool_id=ctx.pool_id, username=username, client_id=client_id,
                             client_secret=client_secret,
                             refresh_token=signed_in.refresh_token if signed_in else None, out=ctx.out)
    if failures:
        raise cleanup_failed_error("breakglass-verify", failures, ctx.pool_id, username,
                                   note=" The sign-in itself succeeded.")
    ctx.out.info("breakglass-verify: OK")
    return 0


def _email_otp_offered(call: dict) -> bool:
    return call.get("challenge") == "EMAIL_OTP" or "EMAIL_OTP" in (call.get("available_challenges") or [])


def _otp_probe_call(idp, *, client_id: str, client_secret: str, username: str, preferred: str | None,
                    log: Output) -> dict:
    """One InitiateAuth USER_AUTH with USERNAME only (no PASSWORD). Never answers the challenge.

    Returns only safe fields: the challenge name, the available first factors and an error code. The
    Session string (and any token, which cannot be issued without a credential) is registered with
    the redactor and dropped.
    """
    params = {"USERNAME": username, "SECRET_HASH": secret_hash(username, client_id, client_secret)}
    if preferred:
        params["PREFERRED_CHALLENGE"] = preferred
    try:
        resp = idp.initiate_auth(AuthFlow="USER_AUTH", ClientId=client_id, AuthParameters=params)
    except Exception as exc:  # noqa: BLE001 - a refusal is a probe result, not a tool failure
        error = (getattr(exc, "response", None) or {}).get("Error") or {}
        return {
            "challenge": None,
            "available_challenges": [],
            "error": error.get("Code") or type(exc).__name__,
            "error_message": log.redact(str(error.get("Message") or ""))[:200],
        }
    log.register(resp.get("Session"))
    result = resp.get("AuthenticationResult") or {}
    log.register(result.get("AccessToken"), result.get("IdToken"), result.get("RefreshToken"))
    return {
        "challenge": resp.get("ChallengeName"),
        "available_challenges": sorted(resp.get("AvailableChallenges") or []),
        "error": None,
        "tokens_issued": bool(result),
    }


def cmd_breakglass_otp_probe(ctx: Ctx, email: str) -> int:
    """ADR 0006a A4 check: does Cognito offer EMAIL_OTP as a first factor to the TOTP-enrolled user?

    Enables the user if it is disabled, asks each client (breakglass, cis-admin) for its first factors
    with InitiateAuth USER_AUTH and USERNAME only, first with no preference, then (only if EMAIL_OTP
    was not already offered) with PREFERRED_CHALLENGE=EMAIL_OTP. It never answers a challenge, never
    reads the break-glass secret (no Secrets Manager client exists for this command) and so never
    issues a token. A `finally` block puts the user back to disabled (global sign-out + disable) when
    it was disabled at the start; a user that was already enabled is left enabled.

    stdout is one JSON document; progress goes to stderr. Exit 0 = EMAIL_OTP not offered on any
    client, 1 = offered (the finding) or inconclusive, 2 = cleanup incomplete (user may be enabled).
    If EMAIL_OTP is offered, Cognito sends one code e-mail to the user's mailbox: that is the finding.
    """
    email = require_staff_email(email)
    log = Output(out=ctx.out.err, err=ctx.out.err, _secrets=ctx.out._secrets)  # progress -> stderr
    clients = []
    for short in OTP_PROBE_CLIENTS:
        name = f"aa-workforce-{ctx.env}-{short}"
        clients.append((name, find_client_id(ctx.idp, ctx.pool_id, name)))
    user = find_user(ctx.idp, ctx.pool_id, email)
    if user is None:
        raise ToolError(f"no WORKFORCE user with email {email}; nothing was changed")
    enabled_at_start = bool(user.get("Enabled"))
    secrets_by_client = {cid: client_secret_of(ctx.idp, ctx.pool_id, cid, log) for _, cid in clients}
    username = email
    report: dict = {
        "probe": "breakglass-otp-probe",
        "user": email,
        "user_status": user.get("UserStatus"),
        "enabled_at_start": enabled_at_start,
        "clients": [],
    }
    error: Exception | None = None
    failures: list[str] = []
    try:
        if enabled_at_start:
            log.warn("WARNING user was already ENABLED: it is left enabled afterwards. Is a break-glass "
                     "sign-in running at the same time? (the probe and that test must not overlap)")
        else:
            ctx.idp.admin_enable_user(UserPoolId=ctx.pool_id, Username=username)
            log.info("user: enabled for the probe")
        for name, cid in clients:
            kwargs = dict(client_id=cid, client_secret=secrets_by_client[cid], username=username, log=log)
            first = _otp_probe_call(ctx.idp, preferred=None, **kwargs)
            if _email_otp_offered(first):
                second = {"skipped": "EMAIL_OTP already offered without a preference"}
            else:
                second = _otp_probe_call(ctx.idp, preferred="EMAIL_OTP", **kwargs)
            report["clients"].append({
                "client": name,
                "client_id": cid,
                "no_preference": first,
                "prefer_email_otp": second,
                "email_otp_offered": _email_otp_offered(first) or _email_otp_offered(second),
            })
            log.info(f"probe: {name} done")
    except Exception as exc:  # noqa: BLE001 - re-raised after cleanup
        error = exc
    finally:
        if not enabled_at_start:
            failures = close_out(ctx.idp, pool_id=ctx.pool_id, username=username, client_id=None,
                                 client_secret=None, refresh_token=None, out=log)
    report["restored"] = not failures
    report["cleanup_failures"] = failures
    entries = report["clients"]
    offered = any(c["email_otp_offered"] for c in entries)
    tokens = any(c[k].get("tokens_issued") for c in entries for k in ("no_preference", "prefer_email_otp"))
    conclusive = len(entries) == len(clients) and all(c["no_preference"]["error"] is None for c in entries)
    if tokens:
        report["verdict"] = "tokens_issued"
    elif offered:
        report["verdict"] = "email_otp_offered"
    elif error is None and conclusive:
        report["verdict"] = "email_otp_not_offered"
    else:
        report["verdict"] = "inconclusive"
    report["email_otp_offered"] = offered
    if error is not None:
        report["error"] = log.redact(f"{type(error).__name__}: {error}")[:300]
    ctx.out.info(json.dumps(report, indent=2, sort_keys=True))
    if failures:
        note = f" The probe also failed: {report['error']}." if error is not None else ""
        raise CleanupIncomplete(
            cleanup_failed_error("breakglass-otp-probe", failures, ctx.pool_id, username, note=note).args[0]
        )
    if error is not None:
        raise error
    if tokens:
        log.warn("WARNING Cognito issued a token without a credential: sign the user out everywhere "
                 f"(aws cognito-idp admin-user-global-sign-out --user-pool-id {ctx.pool_id} --username "
                 f"{username} --profile aa365-admin --region us-west-1) and report it")
        return 1
    if offered:
        log.warn("FINDING EMAIL_OTP is offered to this user: anyone holding the mailbox could sign in "
                 "with an e-mail code. One code e-mail was sent. Bring the fix options to Nghiep "
                 "(ADR 0006a A4).")
        return 1
    if report["verdict"] != "email_otp_not_offered":
        log.warn("probe INCONCLUSIVE: at least one client returned an error without a challenge")
        return 1
    log.info("breakglass-otp-probe: OK (EMAIL_OTP not offered on any client)")
    return 0


def _default_http_post(url: str, form: dict, basic: tuple[str, str]) -> dict:
    data = urllib.parse.urlencode(form).encode()
    auth = base64.b64encode(f"{basic[0]}:{basic[1]}".encode()).decode()
    req = urllib.request.Request(url, data=data, method="POST", headers={
        "Content-Type": "application/x-www-form-urlencoded",
        "Authorization": f"Basic {auth}",
    })
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:  # noqa: S310 - fixed https Cognito URL
            body = resp.read().decode() or "{}"
            return {"status": resp.status, "json": json.loads(body) if body.strip().startswith("{") else {}}
    except urllib.error.HTTPError as exc:
        body = exc.read().decode(errors="replace")
        try:
            parsed = json.loads(body)
        except ValueError:
            parsed = {}
        return {"status": exc.code, "json": parsed}


def cmd_authorize_url(ctx: Ctx, client: str, redirect: str, domain: str, state_dir: Path) -> int:
    client_name = f"aa-workforce-{ctx.env}-{client}"
    client_id = find_client_id(ctx.idp, ctx.pool_id, client_name)
    verifier, challenge = pkce_pair()
    state = secrets.token_urlsafe(24)
    path = state_dir / "pkce-pending.json"
    write_private_json(path, {
        "client_name": client_name,
        "client_id": client_id,
        "redirect_uri": redirect,
        "state": state,
        "code_verifier": verifier,
        "domain": domain,
        "created_at": int(ctx.clock()),
    })
    ctx.out.register(verifier)
    query = urllib.parse.urlencode({
        "response_type": "code",
        "client_id": client_id,
        "redirect_uri": redirect,
        "scope": OAUTH_SCOPES,
        "state": state,
        "code_challenge": challenge,
        "code_challenge_method": "S256",
    }, quote_via=urllib.parse.quote)
    ctx.out.info(f"pkce: verifier + state saved to {path} (mode 0600)")
    ctx.out.info("open this URL, sign in, then paste the full callback URL to exchange-code (code valid 5 min):")
    ctx.out.info(f"{domain.rstrip('/')}/oauth2/authorize?{query}")
    return 0


def cmd_exchange_code(ctx: Ctx, callback_url: str, state_dir: Path) -> int:
    path = state_dir / "pkce-pending.json"
    try:
        pending = json.loads(path.read_text())
    except (OSError, ValueError):
        raise ToolError(f"no pending authorize request at {path}; run authorize-url first") from None
    ctx.out.register(pending.get("code_verifier"))
    parsed = urllib.parse.urlparse(callback_url.strip())
    query = urllib.parse.parse_qs(parsed.query)
    code = (query.get("code") or [""])[0]
    state = (query.get("state") or [""])[0]
    ctx.out.register(code)
    if query.get("error"):
        raise ToolError(f"callback carries error={query['error'][0]!r} "
                        f"{(query.get('error_description') or [''])[0]!r}")
    if not state or not hmac.compare_digest(state, pending.get("state", "")):
        raise ToolError("refused: state does not match the pending authorize request")
    expected = urllib.parse.urlparse(pending["redirect_uri"])
    if (parsed.scheme, parsed.netloc, parsed.path) != (expected.scheme, expected.netloc, expected.path):
        raise ToolError("refused: callback URL does not match the registered redirect_uri")
    if not code:
        raise ToolError("callback URL has no code")
    path.unlink()  # single use, whatever happens next
    client_id = pending["client_id"]
    client_secret = client_secret_of(ctx.idp, ctx.pool_id, client_id, ctx.out)
    domain = pending.get("domain", DEFAULT_HOSTED_DOMAIN).rstrip("/")
    post = ctx.http_post or _default_http_post
    resp = post(f"{domain}/oauth2/token", {
        "grant_type": "authorization_code",
        "client_id": client_id,
        "code": code,
        "redirect_uri": pending["redirect_uri"],
        "code_verifier": pending["code_verifier"],
    }, (client_id, client_secret))
    tokens = resp.get("json") or {}
    if resp.get("status") != 200 or "access_token" not in tokens:
        raise ToolError(f"token exchange failed: HTTP {resp.get('status')} error={tokens.get('error')!r}")
    ctx.out.register(tokens.get("access_token"), tokens.get("id_token"), tokens.get("refresh_token"))
    ctx.out.info(f"token: exchange ok (HTTP 200, expires_in {tokens.get('expires_in')})")
    try:
        for line in claim_summary("access token claims", tokens["access_token"]):
            ctx.out.info(line)
        if tokens.get("id_token"):
            for line in claim_summary("id token claims", tokens["id_token"]):
                ctx.out.info(line)
    finally:
        refresh = tokens.get("refresh_token")
        if refresh:
            rev = post(f"{domain}/oauth2/revoke", {"token": refresh, "client_id": client_id},
                       (client_id, client_secret))
            if rev.get("status") == 200:
                ctx.out.info("revoke: refresh token revoked")
            else:
                ctx.out.warn(f"WARNING revoke failed: HTTP {rev.get('status')}")
    return 0


# --------------------------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------------------------
def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="workforce_bootstrap.py", description=__doc__.split("\n")[0])
    p.add_argument("--profile", default=DEFAULT_PROFILE, help="AWS profile ('' = default chain/env)")
    p.add_argument("--region", default=DEFAULT_REGION)
    p.add_argument("--expect-account", default=DEFAULT_ACCOUNT, help="refuse to run in any other account")
    p.add_argument("--pool-id", default=DEFAULT_POOL_ID)
    p.add_argument("--env", default=DEFAULT_ENV, help="resource name suffix (aa-workforce-<env>-*)")
    sub = p.add_subparsers(dest="cmd", required=True)

    cs = sub.add_parser("create-staff", help="AdminCreateUser (SUPPRESS) + groups; never sets a password")
    cs.add_argument("--email", required=True)
    cs.add_argument("--groups", required=True, help=f"comma-separated, from {','.join(STAFF_GROUPS)}")
    cs.add_argument("--name", default=None, help="optional display name (Cognito `name`)")
    cs.add_argument("--breakglass-email", default=DEFAULT_BREAKGLASS_EMAIL)
    cs.add_argument("--trigger-refusal-test", action="store_true",
                    help="A5 evidence only: out-of-domain address, no groups; expects the pre sign-up "
                         "trigger to refuse (disables the user and fails if it does not)")

    for name, text in (
        ("breakglass-init", "create or rotate break-glass (password + TOTP to Secrets Manager), then disable"),
        ("breakglass-verify", "enable, sign in with password + TOTP, print claims, revoke, disable"),
    ):
        bp = sub.add_parser(name, help=text)
        bp.add_argument("--email", default=DEFAULT_BREAKGLASS_EMAIL)

    op = sub.add_parser("breakglass-otp-probe",
                        help="ADR 0006a A4: is EMAIL_OTP offered to break-glass? No secret read, no token; "
                             "restores the Enabled state")
    op.add_argument("--email", default=DEFAULT_BREAKGLASS_EMAIL)

    au = sub.add_parser("authorize-url", help="spike: managed-login authorize URL with PKCE S256")
    # breakglass is left out on purpose: its managed-login test belongs to C4 (production callback only).
    au.add_argument("--client", default="cis-admin", choices=["cis-admin", "booking-staff"])
    au.add_argument("--redirect", default="http://localhost:3000/api/auth/callback/cognito")
    au.add_argument("--domain", default=DEFAULT_HOSTED_DOMAIN)
    au.add_argument("--state-dir", default=None)

    ex = sub.add_parser("exchange-code", help="spike: exchange the pasted callback URL, print safe claims")
    ex.add_argument("--url", default=None,
                    help="full callback URL from the browser; omit to paste it at a prompt (keeps it out of shell history)")
    ex.add_argument("--state-dir", default=None)
    return p


def _aws_clients(args, out: Output):
    import boto3  # imported here so the pure helpers and tests need no AWS setup

    session = boto3.Session(profile_name=args.profile or None, region_name=args.region)
    try:  # reuse the AWS CLI's assume-role cache (one MFA prompt per 8 h, shared with aws cli)
        from botocore.credentials import JSONFileCache

        provider = session._session.get_component("credential_provider").get_provider("assume-role")
        provider.cache = JSONFileCache(os.path.expanduser(os.path.join("~", ".aws", "cli", "cache")))
    except Exception:  # noqa: BLE001
        pass
    account = session.client("sts").get_caller_identity()["Account"]
    if args.expect_account and account != args.expect_account:
        raise ToolError(f"refused: credentials are for account {account}, expected {args.expect_account}")
    no_sm = args.cmd in NO_SECRETS_MANAGER_COMMANDS
    # The probe keeps stdout for its JSON document, so its preamble goes to stderr.
    (out.warn if no_sm else out.info)(f"aws: account {account}, region {args.region}, pool {args.pool_id}")
    idp = session.client("cognito-idp")
    return idp, (None if no_sm else session.client("secretsmanager"))


def main(argv: list[str] | None = None, out: Output | None = None) -> int:
    out = out or Output()
    args = build_parser().parse_args(argv)
    try:
        idp, sm = _aws_clients(args, out)
        ctx = Ctx(idp=idp, sm=sm, pool_id=args.pool_id, env=args.env, out=out)
        return dispatch(ctx, args)
    except ToolError as exc:
        out.warn(f"ERROR {exc}")
        return exc.exit_code
    except Exception as exc:  # noqa: BLE001 - no traceback: locals/params could carry secrets
        out.warn(f"ERROR {type(exc).__name__}: {exc}")
        return 1


def dispatch(ctx: Ctx, args) -> int:
    if args.cmd == "create-staff":
        return cmd_create_staff(ctx, args.email, args.groups, args.name, args.breakglass_email,
                                args.trigger_refusal_test)
    if args.cmd == "breakglass-init":
        return cmd_breakglass_init(ctx, args.email)
    if args.cmd == "breakglass-verify":
        return cmd_breakglass_verify(ctx, args.email)
    if args.cmd == "breakglass-otp-probe":
        return cmd_breakglass_otp_probe(ctx, args.email)
    state_dir = Path(args.state_dir) if args.state_dir else find_state_dir(Path(__file__).resolve().parent)
    if args.cmd == "authorize-url":
        return cmd_authorize_url(ctx, args.client, args.redirect, args.domain, state_dir)
    if args.cmd == "exchange-code":
        url = args.url or getpass.getpass("paste the full callback URL (not echoed): ")
        return cmd_exchange_code(ctx, url, state_dir)
    raise ToolError(f"unknown command {args.cmd}")


if __name__ == "__main__":
    sys.exit(main())
