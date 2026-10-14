"""Shared helpers for the Cognito identity triggers (AA-703, root ADR 0006 decision 5).

Every trigger fails CLOSED: any exception that leaves a handler makes Cognito refuse the sign-up
or the token. Handlers therefore catch everything, log the real reason, and raise one generic
message, because Cognito shows the exception text to the end user.

The triggers run outside the VPC, have no database access and call only the Cognito API of their
own pool (the pool id comes from the event, never from configuration).
"""

from __future__ import annotations

import json
import os
from typing import Any, Iterable

GENERIC_STAFF_ERROR = "Not authorised for AA staff sign-in"
GENERIC_EXTERNAL_ERROR = "Sign-in is not available for this account"

# Characters that are never accepted in an email used to build a ListUsers filter.
_FORBIDDEN_EMAIL_CHARS = ('"', "\\")


class Deny(Exception):
    """Raised inside a trigger to refuse the request. The reason is logged, never shown."""


def log(event_name: str, **fields: Any) -> None:
    """One structured JSON line per decision (CloudWatch metric filters key on `event`)."""
    print(json.dumps({"event": event_name, **fields}, default=str, sort_keys=True))


def env_list(name: str, default: str = "") -> list[str]:
    raw = os.environ.get(name, default)
    return [item.strip() for item in raw.split(",") if item.strip()]


def env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None or raw.strip() == "":
        return default
    value = raw.strip().lower()
    if value in ("true", "1", "yes"):
        return True
    if value in ("false", "0", "no"):
        return False
    # A typo in configuration must not silently disable a check.
    raise Deny(f"invalid boolean in {name}: {raw!r}")


def normalise_email(value: Any) -> str:
    """Lower-cased, trimmed email, or Deny if it is missing or unsafe for a ListUsers filter."""
    if not isinstance(value, str):
        raise Deny("email missing")
    email = value.strip().lower()
    if not email or email.count("@") != 1:
        raise Deny("email malformed")
    if any(ch in email for ch in _FORBIDDEN_EMAIL_CHARS) or any(ord(ch) < 0x20 for ch in email):
        raise Deny("email contains forbidden characters")
    local, domain = email.split("@")
    if not local or not domain:
        raise Deny("email malformed")
    return email


def email_in_domain(email: str, domain: str) -> bool:
    return bool(domain) and email.endswith("@" + domain.lower())


def is_true(value: Any) -> bool:
    """Cognito passes attribute values as strings ("true"/"false")."""
    return value is True or (isinstance(value, str) and value.strip().lower() == "true")


def user_attr(user: dict, name: str) -> str | None:
    for attr in user.get("Attributes", []) or []:
        if attr.get("Name") == name:
            return attr.get("Value")
    return None


def parse_identities(raw: str | None) -> list[dict]:
    """The `identities` attribute is a JSON array; empty or missing means no linked IdP."""
    if raw is None or raw.strip() in ("", "[]"):
        return []
    parsed = json.loads(raw)
    if not isinstance(parsed, list):
        raise Deny("identities attribute is not a list")
    return parsed


def split_federated_username(user_name: str) -> tuple[str, str]:
    """`Google_1234` / `google_1234` / `Facebook_99` -> ("google", "1234")."""
    if not isinstance(user_name, str) or "_" not in user_name:
        raise Deny("federated username malformed")
    provider, subject = user_name.split("_", 1)
    if not provider or not subject:
        raise Deny("federated username malformed")
    return provider.lower(), subject


def native_users_with_email(cognito: Any, user_pool_id: str, email: str) -> list[dict]:
    """Native (non-federated) users whose email equals `email` exactly (after lower-casing).

    ListUsers does not count as MAU (AdminGetUser does), see ADR 0006 decision 3. A result that
    needs pagination is treated as ambiguous and refused.
    """
    response = cognito.list_users(
        UserPoolId=user_pool_id,
        Filter=f'email = "{email}"',
        Limit=60,
    )
    if response.get("PaginationToken"):
        raise Deny("ListUsers result is paginated, refusing an ambiguous match")
    users = response.get("Users", []) or []
    return [
        u
        for u in users
        if u.get("UserStatus") != "EXTERNAL_PROVIDER"
        and (user_attr(u, "email") or "").strip().lower() == email
    ]


def link_google_identity(
    cognito: Any, user_pool_id: str, native_username: str, provider_name: str, subject: str
) -> None:
    cognito.admin_link_provider_for_user(
        UserPoolId=user_pool_id,
        DestinationUser={"ProviderName": "Cognito", "ProviderAttributeValue": native_username},
        SourceUser={
            "ProviderName": provider_name,
            "ProviderAttributeName": "Cognito_Subject",
            "ProviderAttributeValue": subject,
        },
    )


def provider_links(identities: Iterable[dict], provider_name: str) -> list[dict]:
    wanted = provider_name.lower()
    return [i for i in identities if str(i.get("providerName", "")).lower() == wanted]


def ensure_no_auto_flags(event: dict) -> dict:
    """Triggers never auto-confirm or auto-verify (ADR 0006 decision 6)."""
    response = event.setdefault("response", {})
    response["autoConfirmUser"] = False
    response["autoVerifyEmail"] = False
    response["autoVerifyPhone"] = False
    return event


def cognito_client() -> Any:
    import boto3  # imported lazily so unit tests run without boto3

    return boto3.client("cognito-idp")
