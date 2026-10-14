"""WORKFORCE pool triggers (staff). Root ADR 0006 decisions 3, 4, 5, 11 (as accepted S236).

Staff sign in with an email one-time code only (ADR 0006 "Decisions on open items": adventure.asia
mail is not on Google Workspace, so there is no `hd` claim and no Internal consent screen). The
pool has no social identity provider, so the only legitimate pre sign-up is the staff directory
(AA-816) creating a user with AdminCreateUser. A staff member can sign in if and only if the
directory pre-created an enabled user for that @adventure.asia email and put it in a staff group;
the pre token trigger enforces the domain and the groups on every issue, including refresh.

Configuration (Lambda environment, set by accounts/aa365/identity.tf):
  ALLOWED_EMAIL_DOMAIN     staff email domain, e.g. adventure.asia (required; empty = deny all)
  STAFF_GROUPS             groups kept in tokens; any other group is stripped
  BREAKGLASS_EMAIL         break-glass address; every token issue for it logs an alarm line
"""

from __future__ import annotations

import os
from typing import Any

from common import (
    GENERIC_STAFF_ERROR,
    Deny,
    email_in_domain,
    ensure_no_auto_flags,
    env_list,
    is_true,
    log,
    normalise_email,
)

DEFAULT_STAFF_GROUPS = (
    "cis-admin,cis-reviewer,cis-content,booking-admin,booking-sales,booking-contracting"
)


def _allowed_domain() -> str:
    domain = os.environ.get("ALLOWED_EMAIL_DOMAIN", "").strip().lower()
    if not domain:
        raise Deny("ALLOWED_EMAIL_DOMAIN not configured")
    return domain


# ---------------------------------------------------------------------------------------------
# Pre sign-up. Pure function of the event: no Cognito call, so the trigger role has no Cognito
# permission at all.
# ---------------------------------------------------------------------------------------------
def pre_sign_up(event: dict, context: Any = None) -> dict:
    try:
        return _pre_sign_up(event)
    except Deny as exc:
        log("workforce_pre_sign_up_denied", reason=str(exc), trigger=event.get("triggerSource"))
    except Exception as exc:  # noqa: BLE001 - fail closed on anything unexpected
        log("workforce_pre_sign_up_error", error=repr(exc), trigger=event.get("triggerSource"))
    raise Exception(GENERIC_STAFF_ERROR)


def _pre_sign_up(event: dict) -> dict:
    source = event.get("triggerSource")
    domain = _allowed_domain()
    attrs = (event.get("request") or {}).get("userAttributes") or {}

    if source != "PreSignUp_AdminCreateUser":
        # Self sign-up is impossible (admin-create-only pool) and the pool has no social IdP
        # (PreSignUp_ExternalProvider), but refuse anything that is not the directory anyway.
        raise Deny(f"trigger source not allowed: {source}")

    # The staff directory creating a user. Defence in depth: only staff-domain addresses.
    email = normalise_email(attrs.get("email"))
    if not email_in_domain(email, domain):
        raise Deny("admin-created user outside the staff domain")
    log("workforce_admin_create_allowed", email=email)
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
