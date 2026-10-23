#!/usr/bin/env python3
"""AA-932 (CRM-04) live check of the CRM KMS key alarms: "a test PutKeyPolicy matches each key's alarm rule" (card E
check), without touching a key. Read-only: describe-key, describe-rule and test-event-pattern (EventBridge evaluates a
sample event against the LIVE rule pattern; nothing is published, no key policy changes).

Run after the apply (MFA profile, single-line AWS CLI underneath):
  python3 tools/terraform/crm_kms_alarm_check.py --profile aa365-admin --region us-west-1 --env dev

For each key alias/crm-<env>/{data,ingest,seal}:
  admin.<key>.{PutKeyPolicy,CreateGrant,ScheduleKeyDeletion,DisableKey}    rule aa-crm-<env>-kms-key-admin -> match
  foreign.<key>.admin-role-crypto        crypto call by another role                rule ...-kms-foreign-use -> match
  foreign.<key>.task-role-crypto         crypto call by aa-crm-<env>-ecs-task-role  rule ...-kms-foreign-use -> NO match
  foreign.<key>.aws-service              crypto call by an AWS service (SES)        rule ...-kms-foreign-use -> NO match
plus admin.other-key: a PutKeyPolicy on a key that is not a CRM key -> NO match. Exit 1 if any check is wrong.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys

# TagResource / UntagResource (AA-932 review): the CI boundary deny on CRM keys keys on the tag App = crm.
ADMIN_EVENTS = ("PutKeyPolicy", "CreateGrant", "ScheduleKeyDeletion", "DisableKey", "TagResource", "UntagResource")
CRYPTO_EVENT = {"data": "Decrypt", "ingest": "GenerateDataKey", "seal": "Sign"}


def cloudtrail_event(account: str, region: str, name: str, key_arn: str, key_id: str, identity: dict) -> dict:
    """An EventBridge 'AWS API Call via CloudTrail' event for a KMS call, as CloudTrail writes it."""
    return {
        "version": "0", "id": "aa932-live-check", "detail-type": "AWS API Call via CloudTrail", "source": "aws.kms",
        "account": account, "time": "2026-10-23T00:00:00Z", "region": region, "resources": [],
        "detail": {"eventSource": "kms.amazonaws.com", "eventName": name, "userIdentity": identity,
                   "resources": [{"ARN": key_arn, "accountId": account, "type": "AWS::KMS::Key"}],
                   "requestParameters": {"keyId": key_id}, "sourceIPAddress": "203.0.113.10",
                   "eventTime": "2026-10-23T00:00:00Z"},
    }


def role_identity(account: str, role: str) -> dict:
    return {"type": "AssumedRole", "arn": f"arn:aws:sts::{account}:assumed-role/{role}/aa932-live-check",
            "sessionContext": {"sessionIssuer": {"type": "Role", "arn": f"arn:aws:iam::{account}:role/{role}"}}}


SERVICE_IDENTITY = {"type": "AWSService", "invokedBy": "ses.amazonaws.com"}


def cases(account: str, region: str, env: str, keys: dict) -> list:
    """(check id, rule name, event, expected match) for every check; keys = {name: (key id, key arn)}."""
    admin_rule, foreign_rule = f"aa-crm-{env}-kms-key-admin", f"aa-crm-{env}-kms-foreign-use"
    admin = role_identity(account, "nghiep-admin-8h-session")
    task = role_identity(account, f"aa-crm-{env}-ecs-task-role")
    breakglass = role_identity(account, f"aa-crm-{env}-breakglass")
    out = []
    for name, (key_id, arn) in sorted(keys.items()):
        for ev in ADMIN_EVENTS:
            out.append((f"admin.{name}.{ev}", admin_rule, cloudtrail_event(account, region, ev, arn, key_id, admin),
                        True))
        crypto = CRYPTO_EVENT[name]
        out.append((f"foreign.{name}.admin-role-crypto", foreign_rule,
                    cloudtrail_event(account, region, crypto, arn, key_id, admin), True))
        out.append((f"foreign.{name}.breakglass-crypto", foreign_rule,
                    cloudtrail_event(account, region, crypto, arn, key_id, breakglass), True))
        out.append((f"foreign.{name}.task-role-crypto", foreign_rule,
                    cloudtrail_event(account, region, crypto, arn, key_id, task), False))
        out.append((f"foreign.{name}.aws-service", foreign_rule,
                    cloudtrail_event(account, region, crypto, arn, key_id, SERVICE_IDENTITY), False))
    other = f"arn:aws:kms:{region}:{account}:key/00000000-0000-0000-0000-000000000000"
    out.append(("admin.other-key", admin_rule,
                cloudtrail_event(account, region, "PutKeyPolicy", other, other.rsplit("/", 1)[1], admin), False))
    return out


def aws(args: list, profile: str, region: str) -> dict:
    cmd = ["aws", *args, "--profile", profile, "--region", region, "--output", "json"]
    p = subprocess.run(cmd, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=60)
    if p.returncode != 0:
        raise RuntimeError(f"{' '.join(args[:2])}: {p.stderr.strip()[:300]}")
    return json.loads(p.stdout or "{}")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--profile", default="aa365-admin")
    ap.add_argument("--region", default="us-west-1")
    ap.add_argument("--env", default="dev")
    a = ap.parse_args(argv)
    account = aws(["sts", "get-caller-identity"], a.profile, a.region)["Account"]
    keys = {}
    for name in CRYPTO_EVENT:
        meta = aws(["kms", "describe-key", "--key-id", f"alias/crm-{a.env}/{name}"], a.profile, a.region)["KeyMetadata"]
        keys[name] = (meta["KeyId"], meta["Arn"])
    patterns = {}
    failed = 0
    for cid, rule, event, expected in cases(account, a.region, a.env, keys):
        if rule not in patterns:
            patterns[rule] = aws(["events", "describe-rule", "--name", rule], a.profile, a.region)["EventPattern"]
        got = aws(["events", "test-event-pattern", "--event-pattern", patterns[rule], "--event", json.dumps(event)],
                  a.profile, a.region)["Result"]
        ok = got is expected
        failed += not ok
        print(f"{'ok  ' if ok else 'FAIL'} {cid:<40} rule={rule} match={got} expected={expected}")
    print(f"{failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
