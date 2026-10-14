"""EXTERNAL pool triggers (tenant users + travellers). Root ADR 0006 decisions 3, 5, 6.

The pre sign-up trigger decides by app client. The client id cannot be put in the Lambda
environment (pool -> trigger -> client id would be a Terraform cycle), so the trigger resolves
the client NAME with DescribeUserPoolClient on its own pool (cached per container) and maps it:

  PORTAL_CLIENT_NAMES     (e.g. aa-external-dev-cis-portal) -> every self/federated sign-up refused
  TRAVELLER_CLIENT_NAMES  (e.g. aa-external-dev-tripplanner, aa-external-dev-booking-customer)
                          -> native sign-up allowed, federated sign-up allowed; a Google identity
                          is linked to an existing native user only on a verified email
  anything else / missing -> refused (fail closed)

NATIVE_SIGNUP_ENABLED ("true" only once SES/EMAIL_OTP is live) gates native SignUp on traveller
clients; federated sign-up does not depend on it.

AdminCreateUser (CIS invitations, Phase 3) is always allowed. Facebook is never linked.
"""

from __future__ import annotations

import os
from typing import Any

from common import (
    GENERIC_EXTERNAL_ERROR,
    Deny,
    cognito_client,
    ensure_no_auto_flags,
    env_bool,
    env_list,
    is_true,
    link_google_identity,
    log,
    native_users_with_email,
    normalise_email,
    parse_identities,
    provider_links,
    split_federated_username,
    user_attr,
)

# Attributes a native SignUp may never set itself (proof of email comes only from the code).
_FORBIDDEN_SIGNUP_ATTRIBUTES = ("email_verified", "phone_number_verified")

_client_name_cache: dict[str, str] = {}


def _client_class(cognito: Any, pool_id: str, client_id: str | None) -> str:
    if not client_id or client_id == "CLIENT_ID_NOT_APPLICABLE":
        raise Deny("client id missing")
    name = _client_name_cache.get(client_id)
    if name is None:
        response = cognito.describe_user_pool_client(UserPoolId=pool_id, ClientId=client_id)
        name = response["UserPoolClient"]["ClientName"]
        _client_name_cache[client_id] = name
    if name in env_list("PORTAL_CLIENT_NAMES"):
        return "portal"
    if name in env_list("TRAVELLER_CLIENT_NAMES"):
        return "traveller"
    raise Deny(f"client not allowed: {name}")


# ---------------------------------------------------------------------------------------------
# Pre sign-up
# ---------------------------------------------------------------------------------------------
def pre_sign_up(event: dict, context: Any = None, cognito: Any = None) -> dict:
    try:
        return _pre_sign_up(event, cognito)
    except Deny as exc:
        log("external_pre_sign_up_denied", reason=str(exc), trigger=event.get("triggerSource"))
    except Exception as exc:  # noqa: BLE001 - fail closed
        log("external_pre_sign_up_error", error=repr(exc), trigger=event.get("triggerSource"))
    raise Exception(GENERIC_EXTERNAL_ERROR)


def _pre_sign_up(event: dict, cognito: Any) -> dict:
    source = event.get("triggerSource")
    attrs = (event.get("request") or {}).get("userAttributes") or {}

    if source == "PreSignUp_AdminCreateUser":
        log("external_admin_create_allowed")
        return ensure_no_auto_flags(event)

    if source not in ("PreSignUp_SignUp", "PreSignUp_ExternalProvider"):
        raise Deny(f"trigger source not allowed: {source}")

    pool_id = event["userPoolId"]
    cognito = cognito or cognito_client()
    client_id = (event.get("callerContext") or {}).get("clientId")
    client_class = _client_class(cognito, pool_id, client_id)

    if client_class == "portal":
        # Tenant users exist only by invitation (AdminCreateUser). Hygiene, not the boundary:
        # tenant membership in the CIS database is the security boundary (ADR 0006 decision 3).
        raise Deny("self sign-up refused on the tenant portal client")

    # Traveller clients from here on.
    if source == "PreSignUp_SignUp":
        if not env_bool("NATIVE_SIGNUP_ENABLED", False):
            # Before SES (AA-811) EMAIL_OTP is off, so a native sign-up could only be a password
            # account (not offered to travellers, ADR 0006 decision 4) and every attempt is an MAU.
            raise Deny("native sign-up disabled until EMAIL_OTP is enabled")
        for name in _FORBIDDEN_SIGNUP_ATTRIBUTES:
            if name in attrs:
                raise Deny(f"sign-up may not set {name}")
        if any(name.startswith("custom:") for name in attrs):
            raise Deny("sign-up may not set custom attributes")
        normalise_email(attrs.get("email"))
        log("external_sign_up_allowed", client=client_class)
        return ensure_no_auto_flags(event)

    provider, subject = split_federated_username(event.get("userName", ""))
    google_name = os.environ.get("GOOGLE_PROVIDER_NAME", "Google")
    facebook_name = os.environ.get("FACEBOOK_PROVIDER_NAME", "Facebook")

    if provider == facebook_name.lower():
        # Facebook sends no email_verified: never linked, always its own profile.
        log("external_facebook_sign_up_allowed")
        return ensure_no_auto_flags(event)
    if provider != google_name.lower():
        raise Deny(f"provider not allowed: {provider}")

    if not is_true(attrs.get("email_verified")) or not attrs.get("email"):
        log("external_google_sign_up_unlinked", reason="email not verified")
        return ensure_no_auto_flags(event)

    email = normalise_email(attrs.get("email"))
    candidates = native_users_with_email(cognito, pool_id, email)
    if len(candidates) > 1:
        raise Deny("more than one native user with this email")
    if not candidates:
        log("external_google_sign_up_unlinked", reason="no native user")
        return ensure_no_auto_flags(event)

    target = candidates[0]
    eligible = (
        target.get("Enabled", False)
        and target.get("UserStatus") == "CONFIRMED"
        and is_true(user_attr(target, "email_verified"))
    )
    if not eligible:
        # An UNCONFIRMED or unverified native user is never a link target (ADR 0006 decision 6).
        log("external_google_sign_up_unlinked", reason="target not eligible")
        return ensure_no_auto_flags(event)

    links = provider_links(parse_identities(user_attr(target, "identities")), google_name)
    if links:
        if any(str(link.get("userId")) == subject for link in links):
            log("external_link_already_present")
            return ensure_no_auto_flags(event)
        log("external_google_sign_up_unlinked", reason="target already has a Google link")
        return ensure_no_auto_flags(event)

    link_google_identity(cognito, pool_id, target["Username"], google_name, subject)
    log("external_google_linked")
    return ensure_no_auto_flags(event)


# ---------------------------------------------------------------------------------------------
# Pre token generation (V2_0). Pure: removes every group, adds email claims to the access token.
# ---------------------------------------------------------------------------------------------
def pre_token_generation(event: dict, context: Any = None) -> dict:
    try:
        return _pre_token_generation(event)
    except Exception as exc:  # noqa: BLE001 - fail closed
        log("external_pre_token_error", error=repr(exc), trigger=event.get("triggerSource"))
    raise Exception(GENERIC_EXTERNAL_ERROR)


def _pre_token_generation(event: dict) -> dict:
    attrs = (event.get("request") or {}).get("userAttributes") or {}
    claims: dict[str, str] = {}
    raw_email = attrs.get("email")
    if raw_email:
        claims["email"] = normalise_email(raw_email)
        claims["email_verified"] = "true" if is_true(attrs.get("email_verified")) else "false"
    else:
        claims["email_verified"] = "false"

    event["response"] = {
        "claimsAndScopeOverrideDetails": {
            "idTokenGeneration": {},
            "accessTokenGeneration": {"claimsToAddOrOverride": claims},
            "groupOverrideDetails": {"groupsToOverride": [], "iamRolesToOverride": []},
        }
    }
    return event
