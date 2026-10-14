"""Test fixtures for the Cognito identity triggers (AA-703). Run from accounts/aa365:

    python3 -m pytest -p no:cacheprovider lambda_src/identity_triggers_tests
"""

from __future__ import annotations

import json
import os
import sys

import pytest

sys.dont_write_bytecode = True  # keep __pycache__ out of the archive_file source dir
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "identity_triggers"))

POOL_ID = "us-west-1_TESTPOOL"


class FakeCognito:
    """Minimal stand-in for the boto3 cognito-idp client."""

    def __init__(self, users=None, clients=None, paginated=False, fail_list=False):
        self.users = users or []
        self.clients = clients or {}
        self.paginated = paginated
        self.fail_list = fail_list
        self.list_calls = []
        self.link_calls = []
        self.describe_calls = []

    def list_users(self, **kwargs):
        self.list_calls.append(kwargs)
        if self.fail_list:
            raise RuntimeError("throttled")
        wanted = kwargs["Filter"].split('"')[1]
        users = [
            u for u in self.users
            if any(a["Name"] == "email" and a["Value"].lower() == wanted for a in u["Attributes"])
        ]
        response = {"Users": users}
        if self.paginated:
            response["PaginationToken"] = "next"
        return response

    def admin_link_provider_for_user(self, **kwargs):
        self.link_calls.append(kwargs)
        return {}

    def describe_user_pool_client(self, **kwargs):
        self.describe_calls.append(kwargs)
        return {"UserPoolClient": {"ClientName": self.clients[kwargs["ClientId"]]}}


def native_user(email, status="CONFIRMED", enabled=True, verified="true", identities=None,
                username="11111111-aaaa-bbbb-cccc-000000000001"):
    attrs = [{"Name": "email", "Value": email}, {"Name": "email_verified", "Value": verified}]
    if identities is not None:
        attrs.append({"Name": "identities", "Value": json.dumps(identities)})
    return {"Username": username, "UserStatus": status, "Enabled": enabled, "Attributes": attrs}


def federated_user(email, provider="Google", sub="999"):
    return {
        "Username": f"{provider.lower()}_{sub}",
        "UserStatus": "EXTERNAL_PROVIDER",
        "Enabled": True,
        "Attributes": [{"Name": "email", "Value": email}, {"Name": "email_verified", "Value": "true"}],
    }


def sign_up_event(source, user_name="Google_1234567890", attrs=None, client_id="client-x"):
    return {
        "version": "1",
        "region": "us-west-1",
        "userPoolId": POOL_ID,
        "userName": user_name,
        "triggerSource": source,
        "callerContext": {"awsSdkVersion": "x", "clientId": client_id},
        "request": {"userAttributes": {} if attrs is None else attrs},
        "response": {"autoConfirmUser": False, "autoVerifyEmail": False, "autoVerifyPhone": False},
    }


def token_event(attrs, groups, source="TokenGeneration_HostedAuth", client_id="client-x"):
    return {
        "version": "2",
        "userPoolId": POOL_ID,
        "userName": "11111111-aaaa-bbbb-cccc-000000000001",
        "triggerSource": source,
        "callerContext": {"clientId": client_id},
        "request": {
            "userAttributes": attrs,
            "groupConfiguration": {"groupsToOverride": groups, "iamRolesToOverride": []},
            "scopes": ["openid", "email", "profile"],
        },
        "response": {"claimsAndScopeOverrideDetails": None},
    }


@pytest.fixture(autouse=True)
def trigger_env(monkeypatch):
    monkeypatch.setenv("ALLOWED_EMAIL_DOMAIN", "adventure.asia")
    monkeypatch.setenv("GOOGLE_PROVIDER_NAME", "Google")
    monkeypatch.setenv("FACEBOOK_PROVIDER_NAME", "Facebook")
    monkeypatch.setenv("BREAKGLASS_EMAIL", "breakglass@adventure.asia")
    monkeypatch.setenv("PORTAL_CLIENT_NAMES", "aa-external-dev-cis-portal")
    monkeypatch.setenv(
        "TRAVELLER_CLIENT_NAMES", "aa-external-dev-tripplanner,aa-external-dev-booking-customer"
    )
    monkeypatch.setenv("NATIVE_SIGNUP_ENABLED", "true")
    monkeypatch.delenv("STAFF_GROUPS", raising=False)
