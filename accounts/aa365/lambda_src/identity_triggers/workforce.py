"""WORKFORCE pool triggers (staff). Root ADR 0006 decisions 3, 5, 6, 11.

Allow-list source: THE WORKFORCE POOL ITSELF. A staff member may sign in with Google if and only
if the staff directory (AA-816) has pre-created exactly one enabled native user with that email.
There is no DynamoDB table or SSM parameter: the triggers run outside the VPC without database
access (5-second hard timeout), so the directory projects its allow-list into the pool through
AdminCreateUser / AdminDisableUser, and the trigger reads it with ListUsers on its own pool.

Configuration (Lambda environment, set by accounts/aa365/identity.tf):
  ALLOWED_EMAIL_DOMAIN     staff email domain, e.g. adventure.asia (required; empty = deny all)
  REQUIRE_HD               "true" (default) -> the Google `hd` claim must reach the trigger in
                           HD_ATTRIBUTE and equal ALLOWED_EMAIL_DOMAIN. "false" only after Nghiep
                           accepts the ADR fallback (Internal consent screen + allow-list).
  HD_ATTRIBUTE             user attribute that carries the mapped `hd` claim (default custom:hd)
  GOOGLE_PROVIDER_NAME     IdP name in the pool (default Google)
  LINK_TARGET_STATUSES     native user statuses that may receive a Google link
                           (default CONFIRMED,FORCE_CHANGE_PASSWORD; never UNCONFIRMED)
  STAFF_GROUPS             groups kept in tokens; any other group is stripped
  BREAKGLASS_EMAIL         break-glass address; every token issue for it logs an alarm line
"""

from __future__ import annotations

import os
from typing import Any

from common import (
    GENERIC_STAFF_ERROR,
    Deny,
    cognito_client,
    email_in_domain,
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

DEFAULT_STAFF_GROUPS = (
    "cis-admin,cis-reviewer,cis-content,booking-admin,booking-sales,booking-contracting"
)
DEFAULT_LINK_TARGET_STATUSES = "CONFIRMED,FORCE_CHANGE_PASSWORD"


def _allowed_domain() -> str:
    domain = os.environ.get("ALLOWED_EMAIL_DOMAIN", "").strip().lower()
    if not domain:
        raise Deny("ALLOWED_EMAIL_DOMAIN not configured")
    return domain


# ---------------------------------------------------------------------------------------------
# Pre sign-up
# ---------------------------------------------------------------------------------------------
def pre_sign_up(event: dict, context: Any = None, cognito: Any = None) -> dict:
    try:
        return _pre_sign_up(event, cognito)
    except Deny as exc:
        log("workforce_pre_sign_up_denied", reason=str(exc), trigger=event.get("triggerSource"))
    except Exception as exc:  # noqa: BLE001 - fail closed on anything unexpected
        log("workforce_pre_sign_up_error", error=repr(exc), trigger=event.get("triggerSource"))
    raise Exception(GENERIC_STAFF_ERROR)


def _pre_sign_up(event: dict, cognito: Any) -> dict:
    source = event.get("triggerSource")
    domain = _allowed_domain()
    attrs = (event.get("request") or {}).get("userAttributes") or {}

    if source == "PreSignUp_AdminCreateUser":
        # The staff directory creating a user. Defence in depth: only staff-domain addresses.
        email = normalise_email(attrs.get("email"))
        if not email_in_domain(email, domain):
            raise Deny("admin-created user outside the staff domain")
        log("workforce_admin_create_allowed", email=email)
        return ensure_no_auto_flags(event)

    if source != "PreSignUp_ExternalProvider":
        # Self sign-up is impossible (admin-create-only pool), but refuse anything else anyway.
        raise Deny(f"trigger source not allowed: {source}")

    provider, subject = split_federated_username(event.get("userName", ""))
    google_name = os.environ.get("GOOGLE_PROVIDER_NAME", "Google")
    if provider != google_name.lower():
        raise Deny(f"provider not allowed: {provider}")

    if not is_true(attrs.get("email_verified")):
        raise Deny("Google email not verified")
    email = normalise_email(attrs.get("email"))
    if not email_in_domain(email, domain):
        raise Deny("email outside the staff domain")

    if env_bool("REQUIRE_HD", True):
        hd_attribute = os.environ.get("HD_ATTRIBUTE", "custom:hd")
        hd = str(attrs.get(hd_attribute, "")).strip().lower()
        if hd != domain:
            raise Deny(f"hd claim missing or wrong ({hd_attribute}={hd!r})")

    pool_id = event["userPoolId"]
    cognito = cognito or cognito_client()
    candidates = native_users_with_email(cognito, pool_id, email)
    if len(candidates) != 1:
        raise Deny(f"expected exactly one native user, found {len(candidates)}")
    target = candidates[0]

    if not target.get("Enabled", False):
        raise Deny("native user disabled")
    allowed_statuses = set(env_list("LINK_TARGET_STATUSES", DEFAULT_LINK_TARGET_STATUSES))
    allowed_statuses.discard("UNCONFIRMED")  # never a link target (ADR 0006 decision 6)
    if target.get("UserStatus") not in allowed_statuses:
        raise Deny(f"native user status not allowed: {target.get('UserStatus')}")
    if not is_true(user_attr(target, "email_verified")):
        raise Deny("native user email not verified")

    links = provider_links(parse_identities(user_attr(target, "identities")), google_name)
    if links:
        if len(links) == 1 and str(links[0].get("userId")) == subject:
            # Cognito retried the trigger after a successful link: idempotent success.
            log("workforce_link_already_present", email=email)
            return ensure_no_auto_flags(event)
        raise Deny("native user already linked to another Google identity")
    if parse_identities(user_attr(target, "identities")):
        raise Deny("native user already linked to another identity provider")

    link_google_identity(cognito, pool_id, target["Username"], google_name, subject)
    log("workforce_google_linked", email=email)
    return ensure_no_auto_flags(event)


# ---------------------------------------------------------------------------------------------
# Pre token generation (V2_0). Pure function of the event: no network call.
# ---------------------------------------------------------------------------------------------
def pre_token_generation(event: dict, context: Any = None) -> dict:
    try:
        return _pre_token_generation(event)
    except Deny as exc:
        log("workforce_pre_token_denied", reason=str(exc), trigger=event.get("triggerSource"))
    except Exception as exc:  # noqa: BLE001 - fail closed
        log("workforce_pre_token_error", error=repr(exc), trigger=event.get("triggerSource"))
    raise Exception(GENERIC_STAFF_ERROR)


def _pre_token_generation(event: dict) -> dict:
    domain = _allowed_domain()
    request = event.get("request") or {}
    attrs = request.get("userAttributes") or {}

    email = normalise_email(attrs.get("email"))
    if not email_in_domain(email, domain):
        raise Deny("email outside the staff domain")
    if not is_true(attrs.get("email_verified")):
        raise Deny("email not verified")

    staff_groups = set(env_list("STAFF_GROUPS", DEFAULT_STAFF_GROUPS))
    current = (request.get("groupConfiguration") or {}).get("groupsToOverride") or []
    kept = sorted(g for g in current if g in staff_groups)
    if not kept:
        raise Deny("user is in no staff group")

    breakglass = os.environ.get("BREAKGLASS_EMAIL", "").strip().lower()
    if breakglass and email == breakglass:
        # Metric filter in identity.tf turns this line into an alarm (ADR 0006 decision 11).
        log(
            "breakglass_token_issued",
            client_id=(event.get("callerContext") or {}).get("clientId"),
            trigger=event.get("triggerSource"),
        )

    event["response"] = {
        "claimsAndScopeOverrideDetails": {
            "idTokenGeneration": {},
            "accessTokenGeneration": {"claimsToAddOrOverride": {"email": email}},
            "groupOverrideDetails": {"groupsToOverride": kept, "iamRolesToOverride": []},
        }
    }
    return event
