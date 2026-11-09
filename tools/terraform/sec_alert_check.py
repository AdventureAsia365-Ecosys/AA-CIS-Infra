#!/usr/bin/env python3
"""AA-873 live check of the account security alert rules (security_baseline.tf), without changing anything.

Read-only: describe-rule and test-event-pattern. EventBridge evaluates a sample CloudTrail / Access Analyzer event
against the LIVE rule pattern; nothing is published, no e-mail is sent. It proves the patterns before the harmless
real-change test (root .tmp-session/S256/aa873/alert_test.sh), which proves delivery end to end.

Run (MFA profile, single-line AWS CLI underneath):
  python3 tools/terraform/sec_alert_check.py --profile aa365-admin --region us-west-1 --env dev
  python3 tools/terraform/sec_alert_check.py --skip-after-s256     # before the S256 iam_change widening is applied

Rules checked (aa-sec-<env>-*): security-group-change, iam-change, root-activity, cloudtrail-tamper,
access-analyzer-finding, AA-1022 sso-admin-signin-* (security_sso_signin.tf) (all in --region) and global-forward
(us-east-1). Exit 1 if any check is wrong. --skip-sso skips the AA-1022 checks (before that change is applied).

AA-873 (S263) admin session digest (security_sso_session_digest.tf), both optional:
  --digest                      read-only: the Lambda is Active with its settings, the hourly schedule is ENABLED and
                                the log group keeps 365 days.
  --digest-preview SINCE UNTIL  invokes the Lambda in PREVIEW mode over [SINCE, UNTIL] (ISO 8601, e.g. a past real
                                admin session window): it reads CloudTrail Event history only, publishes nothing and
                                touches no state. Prints each digest (already masked) and fails if one still holds an
                                account id, an ARN or a full e-mail address.
  python3 tools/terraform/sec_alert_check.py --digest-only --digest \
      --digest-preview 2026-10-31T00:00:00Z 2026-11-01T00:00:00Z
  (--digest-only skips the rule pattern checks above.)
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile

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


def saml_event(account: str, region: str, role_name: str, regional_path: bool = False) -> dict:
    """AssumeRoleWithSAML as Identity Center records it in a member account (AA-1022): a read-only STS call by a
    SAMLUser, the permission-set role in requestParameters.roleArn (path with the instance region when it is not
    us-east-1)."""
    path = f"aws-reserved/sso.amazonaws.com/{region + '/' if regional_path else ''}"
    ev = trail_event(account, region, "sts", "AssumeRoleWithSAML",
                     {"type": "SAMLUser", "userName": "aa-live-check", "principalId": "EXAMPLE:aa-live-check"},
                     read_only=True)
    ev["detail"]["requestParameters"] = {
        "roleArn": f"arn:aws:iam::{account}:role/{path}{role_name}",
        "principalArn": f"arn:aws:iam::{account}:saml-provider/AWSSSO_0000000000000000_DO_NOT_DELETE",
        "roleSessionName": "aa-live-check",
    }
    return ev


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
    # S274: a root console tab polls read-only APIs by itself; those no longer alert one by one (the sign-in did).
    console_read = trail_event(account, EAST, "notifications", "ListManagedNotificationEvents", root, read_only=True)
    console_read["detail"]["sessionCredentialFromConsole"] = "true"
    out.append(("root.console-read.ListManagedNotificationEvents", rt, region, console_read, False))
    console_write = trail_event(account, EAST, "support", "CreateCase", root)
    console_write["detail"]["sessionCredentialFromConsole"] = "true"
    out.append(("root.console-write.CreateCase", rt, region, console_write, True))
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
    # AA-1022: Identity Center administrator sessions, one rule per permission set, plus the us-east-1 forward.
    sso_admin, sso_aa = f"{p}-sso-admin-signin-administratoraccess", f"{p}-sso-admin-signin-aa-admin"
    # One role name per line (gitleaks generic rule: a keyword such as "Access" followed by a separator and a value).
    admin_role = "AWSReservedSSO_AdministratorAccess_example"
    aa_role = "AWSReservedSSO_AA-Admin_example"
    dev_role = "AWSReservedSSO_AA-Developer_example"
    out.append(("sso.AdministratorAccess", sso_admin, region, saml_event(account, EAST, admin_role), True))
    out.append(("sso.AdministratorAccess-regional", sso_admin, region,
                saml_event(account, region, admin_role, regional_path=True), True))
    out.append(("sso.AdministratorAccess-not-AA-Admin", sso_admin, region, saml_event(account, EAST, aa_role), False))
    out.append(("sso.AA-Admin", sso_aa, region, saml_event(account, region, aa_role, regional_path=True), True))
    out.append(("sso.AA-Developer", sso_aa, region, saml_event(account, region, dev_role, regional_path=True), False))
    out.append(("forward.sso-admin", fwd, EAST, saml_event(account, EAST, admin_role), True))
    out.append(("forward.sso-aa-admin", fwd, EAST, saml_event(account, EAST, aa_role), True))
    out.append(("forward.sso-developer", fwd, EAST, saml_event(account, EAST, dev_role), False))
    return out


def aws(args: list, profile: str, region: str, timeout: int = 60) -> dict:
    cmd = ["aws", *args, "--profile", profile, "--region", region, "--output", "json"]
    p = subprocess.run(cmd, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=timeout)
    if p.returncode != 0:
        raise RuntimeError(f"{' '.join(args[:2])}: {p.stderr.strip()[:300]}")
    return json.loads(p.stdout or "{}")


# ── AA-873 admin session digest ────────────────────────────────────────────────────────────────────────────────────

DIGEST_ENV_KEYS = ("ADMIN_PERMISSION_SETS", "SAML_REGIONS", "ACTIVITY_REGIONS", "LOOKBACK_HOURS", "IDLE_MINUTES",
                   "ALERT_TOPIC_ARN", "STATE_BUCKET", "STATE_KEY", "RUNBOOK_URL")
# What a digest must never hold (the handler masks them; this is the independent check).
LEAKS = {
    "account id": re.compile(r"(?<!\d)\d{12}(?!\d)"),
    "ARN": re.compile(r"arn:"),
    "e-mail address": re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}"),
}


def digest_names(env: str) -> dict:
    return {"function": f"aa-sec-{env}-admin-session-digest", "schedule": f"aa-sec-{env}-admin-session-digest-hourly",
            "group": f"aa-cis-{env}-acp", "log_group": f"/aws/lambda/aa-sec-{env}-admin-session-digest"}


def leaks(text: str) -> list:
    return [name for name, rx in LEAKS.items() if rx.search(text or "")]


def digest_config_problems(fn: dict, schedule: dict, log_groups: list, names: dict) -> list:
    """Problems found in the live configuration (empty list = fine). Pure, for the tests."""
    out = []
    if fn.get("State") != "Active" or fn.get("LastUpdateStatus") not in (None, "Successful"):
        out.append(f"function state {fn.get('State')}/{fn.get('LastUpdateStatus')}")
    env = ((fn.get("Environment") or {}).get("Variables")) or {}
    missing = [k for k in DIGEST_ENV_KEYS if not env.get(k)]
    if missing:
        out.append(f"function env missing {missing}")
    if "us-east-1" not in (env.get("ACTIVITY_REGIONS") or "").split(","):
        out.append("ACTIVITY_REGIONS lacks us-east-1 (global services)")
    if schedule.get("State") != "ENABLED":
        out.append(f"schedule state {schedule.get('State')}")
    if not str((schedule.get("Target") or {}).get("Arn", "")).endswith(f":function:{names['function']}"):
        out.append("schedule target is not the digest function")
    lg = [g for g in log_groups if g.get("logGroupName") == names["log_group"]]
    if not lg or lg[0].get("retentionInDays") != 365:
        out.append("log group missing or retention not 365 days")
    return out


def digest_checks(profile: str, region: str, env: str) -> int:
    n = digest_names(env)
    fn = aws(["lambda", "get-function-configuration", "--function-name", n["function"]], profile, region)
    sch = aws(["scheduler", "get-schedule", "--group-name", n["group"], "--name", n["schedule"]], profile, region)
    lgs = aws(["logs", "describe-log-groups", "--log-group-name-prefix", n["log_group"]], profile, region)
    problems = digest_config_problems(fn, sch, lgs.get("logGroups") or [], n)
    for p in problems:
        print(f"FAIL digest.config {p}")
    if not problems:
        print(f"ok   digest.config function, schedule {sch.get('ScheduleExpression')} and log group")
    return 1 if problems else 0


def preview_problems(status: dict, payload: dict) -> list:
    """Problems in a preview invoke result (pure, for the tests)."""
    if status.get("FunctionError"):
        return [f"function error: {str(payload)[:300]}"]
    if payload.get("preview") is not True:
        return ["the function did not run in preview mode"]
    out = []
    for i, m in enumerate(payload.get("messages") or []):
        found = leaks(m.get("subject", "") + "\n" + m.get("message", ""))
        if found:
            out.append(f"digest {i} holds {', '.join(found)}")
    return out


def digest_preview(profile: str, region: str, env: str, since: str, until: str) -> int:
    n = digest_names(env)
    body = json.dumps({"preview": True, "since": since, "until": until})
    with tempfile.TemporaryDirectory() as d:
        out = os.path.join(d, "out.json")
        status = aws(["lambda", "invoke", "--function-name", n["function"], "--cli-binary-format",
                      "raw-in-base64-out", "--payload", body, "--cli-read-timeout", "900", out], profile, region,
                     timeout=960)
        with open(out, encoding="utf-8") as fh:
            payload = json.load(fh)
    for m in payload.get("messages") or []:
        print(f"--- {m.get('subject')}\n{m.get('message')}\n")
    print(f"preview: {payload.get('sessions_found')} admin session(s) from {payload.get('since')} to "
          f"{payload.get('until')}, {payload.get('digests')} digest(s)")
    problems = preview_problems(status, payload)
    for p in problems:
        print(f"FAIL digest.preview {p}")
    if not problems:
        print("ok   digest.preview masked, nothing published")
    return 1 if problems else 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--profile", default="aa365-admin")
    ap.add_argument("--region", default="us-west-1")
    ap.add_argument("--env", default="dev")
    ap.add_argument("--skip-after-s256", action="store_true",
                    help="skip the IAM verbs added by the S256 widening (live rule not applied yet)")
    ap.add_argument("--skip-sso", action="store_true",
                    help="skip the AA-1022 Identity Center checks (security_sso_signin.tf not applied yet)")
    ap.add_argument("--digest", action="store_true",
                    help="AA-873: check the admin session digest Lambda, schedule and log group (read-only)")
    ap.add_argument("--digest-preview", nargs=2, metavar=("SINCE", "UNTIL"),
                    help="AA-873: invoke the digest Lambda in preview mode over [SINCE, UNTIL] (publishes nothing)")
    ap.add_argument("--digest-only", action="store_true", help="skip the rule pattern checks")
    a = ap.parse_args(argv)
    account = aws(["sts", "get-caller-identity"], a.profile, a.region)["Account"]
    patterns, failed, skipped = {}, 0, 0
    if a.digest:
        failed += digest_checks(a.profile, a.region, a.env)
    if a.digest_preview:
        failed += digest_preview(a.profile, a.region, a.env, *a.digest_preview)
    for cid, rule, region, event, expected in ([] if a.digest_only else cases(account, a.region, a.env)):
        if a.skip_after_s256 and cid.startswith("iam.admin.") and cid.split(".")[-1] in AFTER_S256:
            skipped += 1
            continue
        if a.skip_sso and cid.startswith(("sso.", "forward.sso")):
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
