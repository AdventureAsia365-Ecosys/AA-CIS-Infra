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
  - E2E_TEST_STAFF_EMAIL (CIS E2E, cis-content only, no Booking group; cis-reviewer until the AA-1035 alias removal,
    CIS 375). The CIS directory (migrations 250 and 375, staff_directory.E2E_TEST_STAFF_EMAIL) holds the same rule.
  - E2E_BOOKING_TEST_STAFF_EMAIL (Booking staff admin E2E, booking-admin only, no CIS group). Not in the CIS
    directory (its CHECK refuses the address): created by an admin with AdminCreateUser + SUPPRESS, no password.
    CIS refuses its tokens (no cis-* group -> 403 no_cis_group).
Lookup is exact and ASCII-only: an address whose RAW attribute holds any non-ASCII character never matches, so a
Unicode case-fold (U+212A KELVIN SIGN lower-cases to ASCII 'k') cannot alias an entry. The check runs on the raw value,
before lower-casing (after it the folded address is already ASCII), and stays here, not in common.normalise_email
(the EXTERNAL pool shares that helper).
A code constant on purpose: no configuration can widen it. Removed when the E2E work is finished.

A10b (AA-816, S252, root ADR 0006a A10b): a third address, Dev only, in a SEPARATE read-only map
E2E_DEV_ONLY_TEST_STAFF:
  - E2E_CIS_ADMIN_TEST_STAFF_EMAIL (CIS admin evidence screenshots and the AA-916 WM-07 sentence-action sample by the
    orchestrating agent), cis-admin only, no Booking / CRM group. The CIS directory (migration 283,
    staff_directory.E2E_CIS_ADMIN_TEST_STAFF_EMAIL) holds the same rule, refuses it unless the API's ENVIRONMENT is
    exactly "dev", and caps its session at reads plus the content-quality sentence-apply routes
    (api/middleware/staff_bearer.py). Its sign-in codes land in their own mailbox prefix (e2e_mailbox.tf rule
    e2e-cognito-admin, prefix inbound-admin/), readable only by the MFA admin role.
A10c (AA-1019, S262, root ADR 0006a A10c): a fourth address in the same Dev-only map:
  - E2E_CRM_STAFF_TEST_STAFF_EMAIL (AA-Partner staff console S-02 / S-04 screenshots and live checks by the orchestrating
    agent), exactly crm-ops + crm-support, no CIS / Booking / crm-platform-admin group. AA-Partner refuses its token
    outside dev / test / local and lets it reach synthetic agencies only (api/app/auth/e2e_staff.py). Not in the CIS
    directory: created by an admin with AdminCreateUser + SUPPRESS (tools/identity/crm_dev_identity.py e2e-staff), like
    A10a. Its codes land in the A10b mailbox prefix inbound-admin/ (rule e2e-cognito-admin), readable by the MFA admin
    role only.
A10d (AA-1035, S270, root ADR 0006a A10d): a fifth address in the same Dev-only map:
  - E2E_CIS_CS_TEST_STAFF_EMAIL (live proof of the AA-1035 tenant-book scoping with a real Cognito session by the
    orchestrating agent), exactly cis-customer_success, no Booking / CRM group. The CIS directory (migration 378,
    staff_directory._E2E_TEST_STAFF_ROLES) holds the same rule, refuses it unless the API's ENVIRONMENT is exactly
    "dev", caps its session at reads with NO write allow-list, and assigns it synthetic tenants only. Its codes land in
    the A10b mailbox prefix inbound-admin/ (rule e2e-cognito-admin), readable by the MFA admin role only.
A10e (AA-1087, S278, root ADR 0006a A10e): three more addresses in the same Dev-only map, the write-capable AA-Booking
E2E identities of the synthetic pilot rehearsal:
  - E2E_BOOKING_STAFF_TEST_STAFF_EMAIL, exactly booking-sales (send and confirm a supplier booking);
  - E2E_BOOKING_MAKER_TEST_STAFF_EMAIL and E2E_BOOKING_CHECKER_TEST_STAFF_EMAIL, each exactly booking-finance (record
    an agency payment; approve or reject it). Same group tuple on purpose: AA-Booking separates them by address.
  AA-Booking (app/auth/e2e_staff.py) refuses them outside ENVIRONMENT dev, with any other group set, on any write
  outside the address's own allow-list, and on a record of an agency that CIS does not mark synthetic. Not in the CIS
  directory: created with AdminCreateUser + SUPPRESS, no password (tools/identity/crm_dev_identity.py
  e2e-booking-writers), like A10a / A10c. Codes in the A10b prefix inbound-admin/ (MFA admin role only).
A10e-2 (AA-1091, S279, root ADR 0006a A10e-2): the pricing pair of the AA-1091 live check with SYNTHETIC prices:
  - E2E_CIS_CS_TEST_STAFF_EMAIL (A10d) may also hold exactly cis-customer_success + booking-contracting, the CIS Staff
    page "Pricing team" preset (E2E_DEV_ONLY_EXTRA_GROUP_SETS): the maker. Its A10d set alone stays valid, so the
    account keeps signing in after the preset is removed. The CIS directory allows that one Booking grant on Dev only;
  - E2E_BOOKING_PRICING_CHECKER_TEST_STAFF_EMAIL, exactly booking-contracting: the checker. Not in the CIS directory
    (tools/identity/crm_dev_identity.py e2e-booking-writers), codes in inbound-admin/ like A10e.
  AA-Booking (app/auth/e2e_staff.py) holds both to the pricing steps on synthetic trip plans, Dev only.
The map is consulted only while the Lambda env E2E_DEV_ONLY_STAFF_ENABLED is exactly the string "true" (read per call,
no strip / lower; missing or anything else = off, fail closed). identity.tf sets it to "true" only when
var.environment == "dev" and a precondition refuses "true" anywhere else. The flag can only switch ON an entry whose
address and groups are code constants; it cannot add an address or widen a group set. Same ASCII-only exact lookup.
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
E2E_TEST_STAFF_GROUPS = ("cis-content",)
# AA-910 (S250, Nghiep): Booking staff admin signed-in checks. booking-admin is the least-privileged Booking group
# that reads every staff page, /staff and /audit-log included (AA-Booking backend/app/auth/staff.py PERMISSIONS).
E2E_BOOKING_TEST_STAFF_EMAIL = "e2e-booking@e2e-mail.lumiguides.it.com"
E2E_BOOKING_TEST_STAFF_GROUPS = ("booking-admin",)
# Read-only view: nothing at run time can add an address or widen a group set.
E2E_TEST_STAFF = MappingProxyType({
    E2E_TEST_STAFF_EMAIL: E2E_TEST_STAFF_GROUPS,
    E2E_BOOKING_TEST_STAFF_EMAIL: E2E_BOOKING_TEST_STAFF_GROUPS,
})

# A10b (AA-816, S252): Dev-only CIS admin E2E address. Consulted only when _dev_only_e2e_enabled() (module docstring).
E2E_CIS_ADMIN_TEST_STAFF_EMAIL = "e2e-cis-admin@e2e-mail.lumiguides.it.com"
E2E_CIS_ADMIN_TEST_STAFF_GROUPS = ("cis-admin",)
# A10c (AA-1019, S262): Dev-only AA-Partner staff E2E address; must equal AA-Partner e2e_staff.E2E_CRM_STAFF_EMAIL.
E2E_CRM_STAFF_TEST_STAFF_EMAIL = "e2e-crm-staff@e2e-mail.lumiguides.it.com"
E2E_CRM_STAFF_TEST_STAFF_GROUPS = ("crm-ops", "crm-support")
# A10d (AA-1035, S270): Dev-only CIS customer_success E2E address, read-only in CIS (no write allow-list); must equal
# AA-CIS-App e2e_staff.E2E_CIS_CS_TEST_STAFF_EMAIL and AA-Partner e2e_staff.E2E_CIS_CS_EMAIL.
E2E_CIS_CS_TEST_STAFF_EMAIL = "e2e-cis-cs@e2e-mail.lumiguides.it.com"
E2E_CIS_CS_TEST_STAFF_GROUPS = ("cis-customer_success",)
# A10e (AA-1087, S278): Dev-only write-capable AA-Booking E2E addresses; must equal AA-Booking app/auth/e2e_staff.py.
# Booking holds each one to its own allow-listed writes on synthetic agencies only. The maker and the checker share
# booking-finance on purpose: Booking separates them by address (allow-list) and the agency_payment maker-checker CHECK.
E2E_BOOKING_STAFF_TEST_STAFF_EMAIL = "e2e-booking-staff@e2e-mail.lumiguides.it.com"
E2E_BOOKING_STAFF_TEST_STAFF_GROUPS = ("booking-sales",)
E2E_BOOKING_MAKER_TEST_STAFF_EMAIL = "e2e-booking-maker@e2e-mail.lumiguides.it.com"
E2E_BOOKING_MAKER_TEST_STAFF_GROUPS = ("booking-finance",)
E2E_BOOKING_CHECKER_TEST_STAFF_EMAIL = "e2e-booking-checker@e2e-mail.lumiguides.it.com"
E2E_BOOKING_CHECKER_TEST_STAFF_GROUPS = ("booking-finance",)
# A10e-2 (AA-1091, S279): the pricing checker (Dev only, booking-contracting); must equal AA-Booking
# app/auth/e2e_staff.E2E_PRICING_CHECKER_EMAIL and AA-CIS-App e2e_staff.E2E_BOOKING_PRICING_CHECKER_TEST_STAFF_EMAIL.
E2E_BOOKING_PRICING_CHECKER_TEST_STAFF_EMAIL = "e2e-booking-pricing-checker@e2e-mail.lumiguides.it.com"
E2E_BOOKING_PRICING_CHECKER_TEST_STAFF_GROUPS = ("booking-contracting",)
# A10e-2: the A10d address with the "Pricing team" preset (the pricing maker): exactly these groups, as well as its own.
E2E_CIS_CS_PRICING_TEST_STAFF_GROUPS = ("cis-customer_success", "booking-contracting")
E2E_DEV_ONLY_TEST_STAFF = MappingProxyType({
    E2E_CIS_ADMIN_TEST_STAFF_EMAIL: E2E_CIS_ADMIN_TEST_STAFF_GROUPS,
    E2E_CRM_STAFF_TEST_STAFF_EMAIL: E2E_CRM_STAFF_TEST_STAFF_GROUPS,
    E2E_CIS_CS_TEST_STAFF_EMAIL: E2E_CIS_CS_TEST_STAFF_GROUPS,
    E2E_BOOKING_STAFF_TEST_STAFF_EMAIL: E2E_BOOKING_STAFF_TEST_STAFF_GROUPS,
    E2E_BOOKING_MAKER_TEST_STAFF_EMAIL: E2E_BOOKING_MAKER_TEST_STAFF_GROUPS,
    E2E_BOOKING_CHECKER_TEST_STAFF_EMAIL: E2E_BOOKING_CHECKER_TEST_STAFF_GROUPS,
    E2E_BOOKING_PRICING_CHECKER_TEST_STAFF_EMAIL: E2E_BOOKING_PRICING_CHECKER_TEST_STAFF_GROUPS,
})
# Other exact group sets a Dev-only address may hold, besides its own tuple above (read-only, code constants). Any set
# that is neither still DENIES the token.
E2E_DEV_ONLY_EXTRA_GROUP_SETS = MappingProxyType({
    E2E_CIS_CS_TEST_STAFF_EMAIL: (E2E_CIS_CS_PRICING_TEST_STAFF_GROUPS,),
})
# The Lambda env switch for E2E_DEV_ONLY_TEST_STAFF and the one value that turns it on (compared exactly).
DEV_ONLY_E2E_FLAG = "E2E_DEV_ONLY_STAFF_ENABLED"
DEV_ONLY_E2E_ON = "true"

DEFAULT_STAFF_GROUPS = (
    # AA-1035 R2 close-out: cis-reviewer (alias of content) is retired with CIS 375; a leftover membership is stripped.
    "cis-admin,cis-content,"
    # AA-1035 R2 / root ADR 0019 d3: the six new CIS staff groups and Booking finance (identity.tf local.id_staff_groups).
    "cis-content_lead,cis-ai_ops,cis-customer_success,cis-finance,cis-tenant_qa,cis-support,"
    "booking-admin,booking-sales,booking-contracting,booking-content_creator,booking-finance,"
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
    groups = E2E_TEST_STAFF.get(email)
    if groups is None and _dev_only_e2e_enabled():
        groups = E2E_DEV_ONLY_TEST_STAFF.get(email)
    return groups


def _e2e_groups_match(email: str, kept: list[str], e2e_groups: tuple[str, ...]) -> bool:
    """True when the kept staff groups are exactly the address's tuple or, for a Dev-only address while the flag is on,
    exactly one of its E2E_DEV_ONLY_EXTRA_GROUP_SETS (A10e-2)."""
    if kept == sorted(e2e_groups):
        return True
    extra = E2E_DEV_ONLY_EXTRA_GROUP_SETS.get(email, ()) if _dev_only_e2e_enabled() else ()
    return any(kept == sorted(g) for g in extra)


def _dev_only_e2e_enabled() -> bool:
    """A10b: True only when the Lambda env E2E_DEV_ONLY_STAFF_ENABLED is exactly "true" (no strip, no lower-casing;
    read per call). Missing, empty, "True", " true", "1" ... are all off."""
    return os.environ.get(DEV_ONLY_E2E_FLAG) == DEV_ONLY_E2E_ON


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
        if not _e2e_groups_match(email, kept, e2e_groups):
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
