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

TEMPORARY exception (AA-816, S243 decision "option B", root ADR 0006a A10, A10a; second address AA-910, S250): a
fixed allow-map E2E_TEST_STAFF {address: exact staff groups} of addresses outside the staff domain, each a
mailbox of the SES inbound test domain the email-code E2E tests read their codes from. An address in the map
may be admin-created and may get a token, and only while its staff groups are exactly the tuple it maps to;
any other group set DENIES the token (logged), it is never stripped. Two entries:
  - E2E_TEST_STAFF_EMAIL (CIS E2E, cis-reviewer only, no Booking group). The CIS directory (migration 250,
    staff_directory.E2E_TEST_STAFF_EMAIL) holds the same rule.
  - E2E_BOOKING_TEST_STAFF_EMAIL (Booking staff admin E2E, booking-admin only, no CIS group). Not in the CIS
    directory (its CHECK refuses the address): created by an admin with AdminCreateUser + SUPPRESS, no password.
    CIS refuses its tokens (no cis-* group -> 403 no_cis_group).
Lookup is exact and ASCII-only: an address whose RAW attribute holds any non-ASCII character never matches, so a
Unicode case-fold (U+212A KELVIN SIGN lower-cases to ASCII 'k') cannot alias an entry. The check runs on the raw value,
before lower-casing (after it the folded address is already ASCII), and stays here, not in common.normalise_email
(the EXTERNAL pool shares that helper).
A code constant on purpose: no configuration can widen it. Removed when the E2E work is finished.
"""

from __future__ import annotations

import os
from types import MappingProxyType
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

# TEMPORARY (AA-816, AA-910): see the module docstring. Exact match after lower-casing, ASCII input only (_e2e_groups);
# nothing else matches.
E2E_TEST_STAFF_EMAIL = "e2e@e2e-mail.lumiguides.it.com"
E2E_TEST_STAFF_GROUPS = ("cis-reviewer",)
# AA-910 (S250, Nghiep): Booking staff admin signed-in checks. booking-admin is the least-privileged Booking group
# that reads every staff page, /staff and /audit-log included (AA-Booking backend/app/auth/staff.py PERMISSIONS).
E2E_BOOKING_TEST_STAFF_EMAIL = "e2e-booking@e2e-mail.lumiguides.it.com"
E2E_BOOKING_TEST_STAFF_GROUPS = ("booking-admin",)
# Read-only view: nothing at run time can add an address or widen a group set.
E2E_TEST_STAFF = MappingProxyType({
    E2E_TEST_STAFF_EMAIL: E2E_TEST_STAFF_GROUPS,
    E2E_BOOKING_TEST_STAFF_EMAIL: E2E_BOOKING_TEST_STAFF_GROUPS,
})

DEFAULT_STAFF_GROUPS = (
    "cis-admin,cis-reviewer,cis-content,"
    "booking-admin,booking-sales,booking-contracting,booking-content_creator,"
    # AA-939 / root ADR 0006b decision 6: AA-Partner staff groups.
    "crm-platform-admin,crm-ops,crm-support"
)


def _e2e_groups(raw_email: Any, email: str) -> tuple[str, ...] | None:
    """The exact staff groups of an E2E test address, or None.

    `raw_email` is the email attribute as Cognito sent it, `email` its normalise_email() form. A raw value with any
    non-ASCII character never matches: str.lower() folds some non-ASCII letters to ASCII (U+212A KELVIN SIGN -> 'k'),
    so checking the lower-cased form would be too late and a different Cognito user (another username, another sub)
    could pass as the E2E account.
    """
    if not isinstance(raw_email, str) or not raw_email.isascii():
        return None
    return E2E_TEST_STAFF.get(email)


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

    # The staff directory creating a user. Defence in depth: only staff-domain addresses (and the temporary
    # E2E test addresses of E2E_TEST_STAFF).
    email = normalise_email(attrs.get("email"))
    if _e2e_groups(attrs.get("email"), email) is not None:
        log("workforce_e2e_test_create_allowed", email=email)
        return ensure_no_auto_flags(event)
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
    e2e_groups = _e2e_groups(attrs.get("email"), email)
    e2e_test = e2e_groups is not None
    if not e2e_test and not email_in_domain(email, domain):
        raise Deny("email outside the staff domain")
    if not is_true(attrs.get("email_verified")):
        raise Deny("email not verified")

    staff_groups = set(env_list("STAFF_GROUPS", DEFAULT_STAFF_GROUPS))
    current = (request.get("groupConfiguration") or {}).get("groupsToOverride") or []
    kept = sorted(g for g in current if g in staff_groups)
    if not kept:
        raise Deny("user is in no staff group")
    if e2e_test:
        # Refuse, do not strip: a wider group on this account means the directory rule was bypassed.
        if kept != sorted(e2e_groups):
            raise Deny("E2E test account outside its allowed groups")
        log("workforce_e2e_test_token_issued", trigger=event.get("triggerSource"),
            client_id=(event.get("callerContext") or {}).get("clientId"), email=email)

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
