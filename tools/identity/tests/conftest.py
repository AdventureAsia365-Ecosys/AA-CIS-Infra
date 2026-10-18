"""Fixtures for tools/identity tests (AA-854). Run from the repo root:

    python3 -m pytest -p no:cacheprovider -q tools/identity/tests

No AWS access: every boto3 client is a real botocore client with dummy credentials wrapped in a
botocore Stubber, so an unexpected call fails the test instead of reaching AWS.
"""

from __future__ import annotations

import base64
import json
import os
import sys

import pytest

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import boto3  # noqa: E402
from botocore.stub import Stubber  # noqa: E402

import workforce_bootstrap as wb  # noqa: E402

POOL = "us-west-1_TESTPOOL"
BG_CLIENT_ID = "bgclientid000000000000000a"
CIS_CLIENT_ID = "cisclientid00000000000000a"
CLIENT_SECRET = "CLIENT-SECRET-VALUE-do-not-print-0123456789"


def fake_jwt(claims: dict) -> str:
    def enc(obj):
        return base64.urlsafe_b64encode(json.dumps(obj).encode()).rstrip(b"=").decode()

    return f"{enc({'alg': 'RS256', 'kid': 'k1'})}.{enc(claims)}.c2lnbmF0dXJlLW5vdC1jaGVja2Vk"


def make_client(service: str):
    return boto3.client(
        service, region_name="us-west-1", aws_access_key_id="testing", aws_secret_access_key="testing"
    )


class FakeClock:
    def __init__(self, start: float):
        self.now = start
        self.sleeps: list[float] = []

    def __call__(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.sleeps.append(seconds)
        self.now += seconds


@pytest.fixture(autouse=True)
def no_aws_env(monkeypatch):
    for name in ("AWS_PROFILE", "AWS_DEFAULT_PROFILE"):
        monkeypatch.delenv(name, raising=False)


@pytest.fixture
def stubbed():
    idp, sm = make_client("cognito-idp"), make_client("secretsmanager")
    idp_stub, sm_stub = Stubber(idp), Stubber(sm)
    idp_stub.activate()
    sm_stub.activate()
    yield idp, idp_stub, sm, sm_stub
    idp_stub.deactivate()
    sm_stub.deactivate()


@pytest.fixture
def ctx_factory(stubbed):
    idp, _, sm, _ = stubbed

    def factory(clock=None, http_post=None):
        clock = clock or FakeClock(1_760_000_000.0)
        return wb.Ctx(idp=idp, sm=sm, pool_id=POOL, env="dev", out=wb.Output(),
                      clock=clock, sleep=clock.sleep, http_post=http_post)

    return factory
