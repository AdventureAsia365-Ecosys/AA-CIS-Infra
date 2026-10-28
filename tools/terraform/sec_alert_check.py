#!/usr/bin/env python3
"""AA-873 live check of the account security alert rules (security_baseline.tf), without changing anything.

Read-only: describe-rule and test-event-pattern. EventBridge evaluates a sample CloudTrail / Access Analyzer event
against the LIVE rule pattern; nothing is published, no e-mail is sent. It proves the patterns before the harmless
real-change test (root .tmp-session/S256/aa873/alert_test.sh), which proves delivery end to end.

Run (MFA profile, single-line AWS CLI underneath):
  python3 tools/terraform/sec_alert_check.py --profile aa365-admin --region us-west-1 --env dev
  python3 tools/terraform/sec_alert_check.py --skip-after-s256     # before the S256 iam_change widening is applied

Rules checked (aa-sec-<env>-*): security-group-change, iam-change, root-activity, cloudtrail-tamper,
access-analyzer-finding (all in --region) and global-forward (us-east-1). Exit 1 if any check is wrong.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys

EAST = "us-east-1"
# IAM verbs the iam-change rule matches only after the S256 widening (Tag*/Untag*/Upload*/Set*/Reset*/Change*).
AFTER_S256 = ("TagRole", "UntagRole", "TagPolicy", "UntagPolicy", "UploadSSHPublicKey", "ChangePassword",
              "SetSecurityTokenServicePreferences")


def role_identity(account: str, role: str) -> dict:
    return {"type": "AssumedRole", "arn": f"arn:aws:sts::{account}:assumed-role/{role}/aa873-live-check",
            "principalId": "AROAEXAMPLE:aa873-live-check",
            "sessionContext": {"sessionIssuer": {"type": "Role", "userName": role,
                                                 "arn": f"arn:aws:iam::{account}:role/{role}"}}}


def user_identity(account: str, user: str) -> dict:
    return {"type": "IAMUser", "userName": user, "arn": f"arn:aws:iam::{account}:user/{user}"}


def root_identity(account: str) -> dict:
    return {"type": "Root", "arn": f"arn:aws:iam::{account}:root", "principalId": account}


def trail_event(account: str, region: str, source: str, name: str, identity: dict, read_only: bool = False,
                detail_type: str = "AWS API Call via CloudTrail") -> dict:
    """An EventBridge event as CloudTrail delivers it (IAM events carry awsRegion us-east-1)."""
    return {
        "version": "0", "id": "aa873-live-check", "detail-type": detail_type, "source": f"aws.{source}",
        "account": account, "time": "2026-10-28T00:00:00Z", "region": region, "resources": [],
        "detail": {"eventSource": f"{source}.amazonaws.com", "eventName": name, "userIdentity": identity,
                   "readOnly": read_only, "awsRegion": region, "sourceIPAddress": "203.0.113.10",
                   "eventTime": "2026-10-28T00:00:00Z", "eventType": "AwsApiCall"},
    }


def finding_event(account: str, region: str, status: str) -> dict:
    return {
        "version": "0", "id": "aa873-live-check", "detail-type": "Access Analyzer Finding",
        "source": "aws.access-analyzer", "account": account, "time": "2026-10-28T00:00:00Z", "region": region,
        "resources": [], "detail": {"id": "00000000-0000-0000-0000-000000000000", "status": status,
                                    "resourceType": "AWS::IAM::Role", "isPublic": False,
                                    "resource": f"arn:aws:iam::{account}:role/aa-sec-alert-test"},
    }


def cases(account: str, region: str, env: str) -> list:
    """(check id, rule name, rule region, event, expected match)."""
    p = f"aa-sec-{env}"
    admin = role_identity(account, "aa365-admin-mfa-session")
    apply_role = role_identity(account, "aa-cis-infra-tf-apply")
    user = user_identity(account, "aa873-test-user")
    root = root_identity(account)
    sg, iam, rt, tt = f"{p}-security-group-change", f"{p}-iam-change", f"{p}-root-activity", f"{p}-cloudtrail-tamper"
    aa, fwd = f"{p}-access-analyzer-finding", f"{p}-global-forward"
    out = []
    for ev in ("CreateSecurityGroup", "AuthorizeSecurityGroupIngress", "RevokeSecurityGroupIngress",
               "DeleteSecurityGroup", "ModifySecurityGroupRules"):
        out.append((f"sg.admin.{ev}", sg, region, trail_event(account, region, "ec2", ev, admin), True))
    out.append(("sg.iam-user.AuthorizeSecurityGroupIngress", sg, region,
                trail_event(account, region, "ec2", "AuthorizeSecurityGroupIngress", user), True))
    out.append(("sg.tf-apply.AuthorizeSecurityGroupIngress", sg, region,
                trail_event(account, region, "ec2", "AuthorizeSecurityGroupIngress", apply_role), False))
    out.append(("sg.admin.DescribeSecurityGroups", sg, region,
                trail_event(account, region, "ec2", "DescribeSecurityGroups", admin, read_only=True), False))
    for ev in ("CreatePolicy", "DeletePolicy", "AttachRolePolicy", "DetachRolePolicy", "PutRolePolicy",
               "UpdateAssumeRolePolicy", "CreateAccessKey", "CreateRole", "DeleteRole", "SetDefaultPolicyVersion",
               "DeactivateMFADevice", *AFTER_S256):
        out.append((f"iam.admin.{ev}", iam, region, trail_event(account, EAST, "iam", ev, admin), True))
    out.append(("iam.iam-user.CreateAccessKey", iam, region,
                trail_event(account, EAST, "iam", "CreateAccessKey", user), True))
    out.append(("iam.tf-apply.CreatePolicy", iam, region, trail_event(account, EAST, "iam", "CreatePolicy", apply_role),
                False))
    out.append(("iam.admin.GetRole", iam, region, trail_event(account, EAST, "iam", "GetRole", admin, read_only=True),
                False))
    out.append(("root.ConsoleLogin", rt, region, trail_event(account, EAST, "signin", "ConsoleLogin", root,
                                                             detail_type="AWS Console Sign In via CloudTrail"), True))
    out.append(("root.GetCallerIdentity", rt, region,
                trail_event(account, region, "sts", "GetCallerIdentity", root, read_only=True), True))
    out.append(("root.admin-ConsoleLogin", rt, region, trail_event(account, EAST, "signin", "ConsoleLogin", admin,
                                                                   detail_type="AWS Console Sign In via CloudTrail"),
                False))
    for ev, who, ident in (("UpdateTrail", "admin", admin), ("StopLogging", "tf-apply", apply_role),
                           ("PutEventSelectors", "admin", admin), ("DeleteTrail", "admin", admin)):
        out.append((f"trail.{who}.{ev}", tt, region, trail_event(account, region, "cloudtrail", ev, ident), True))
    out.append(("trail.admin.LookupEvents", tt, region,
                trail_event(account, region, "cloudtrail", "LookupEvents", admin, read_only=True), False))
    out.append(("analyzer.ACTIVE", aa, region, finding_event(account, region, "ACTIVE"), True))
    out.append(("analyzer.ARCHIVED", aa, region, finding_event(account, region, "ARCHIVED"), False))
    out.append(("forward.iam-write", fwd, EAST, trail_event(account, EAST, "iam", "CreatePolicy", admin), True))
    out.append(("forward.iam-tag", fwd, EAST, trail_event(account, EAST, "iam", "TagRole", admin), True))
    out.append(("forward.iam-read", fwd, EAST, trail_event(account, EAST, "iam", "GetRole", admin, read_only=True),
                False))
    out.append(("forward.root-login", fwd, EAST, trail_event(account, EAST, "signin", "ConsoleLogin", root,
                                                             detail_type="AWS Console Sign In via CloudTrail"), True))
    out.append(("forward.admin-sts", fwd, EAST, trail_event(account, EAST, "sts", "GetCallerIdentity", admin,
                                                            read_only=True), False))
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
    ap.add_argument("--skip-after-s256", action="store_true",
                    help="skip the IAM verbs added by the S256 widening (live rule not applied yet)")
    a = ap.parse_args(argv)
    account = aws(["sts", "get-caller-identity"], a.profile, a.region)["Account"]
    patterns, failed, skipped = {}, 0, 0
    for cid, rule, region, event, expected in cases(account, a.region, a.env):
        if a.skip_after_s256 and cid.startswith("iam.admin.") and cid.split(".")[-1] in AFTER_S256:
            skipped += 1
            continue
        if (rule, region) not in patterns:
            patterns[(rule, region)] = aws(["events", "describe-rule", "--name", rule], a.profile, region)["EventPattern"]
        got = aws(["events", "test-event-pattern", "--event-pattern", patterns[(rule, region)],
                   "--event", json.dumps(event)], a.profile, region)["Result"]
        ok = got is expected
        failed += not ok
        print(f"{'ok  ' if ok else 'FAIL'} {cid:<42} rule={rule} match={got} expected={expected}")
    print(f"{failed} failed, {skipped} skipped")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
