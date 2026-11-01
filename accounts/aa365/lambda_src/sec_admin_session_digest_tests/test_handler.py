"""AA-873 (S263) — unit tests for the Identity Center admin session digest. No AWS access.

Run from accounts/aa365 (stdlib unittest, no pytest needed):

    python3 -B -m unittest discover -s lambda_src/sec_admin_session_digest_tests -v

Kept outside lambda_src/sec_admin_session_digest/ so archive_file never packages the tests. Every name, address, key
and account below is invented (documentation IP ranges, example.org, the AWS documentation account 111122223333).
"""

from __future__ import annotations

import io
import json
import os
import re
import sys
import unittest
from datetime import datetime, timedelta, timezone

sys.dont_write_bytecode = True  # keep __pycache__ out of the archive_file source dir
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "sec_admin_session_digest"))

import handler as h  # noqa: E402

ACCOUNT = "111122223333"
USER = "lan.tester@example.org"
OTHER_USER = "minh.sample@example.org"
# One role name per line (gitleaks generic rule).
ADMIN_ROLE = "AWSReservedSSO_AdministratorAccess_0a1b2c"
AA_ROLE = "AWSReservedSSO_AA-Admin_0d0e0f"
DEV_ROLE = "AWSReservedSSO_AA-Developer_0a0b0c"
CLI_KEY = "KEYCLIAAAAAAAAAA"
CONSOLE_KEY = "KEYCONSOLEAAAAAA"
SETS = {"AdministratorAccess", "AA-Admin"}
T0 = datetime(2026, 10, 30, 2, 0, 0, tzinfo=timezone.utc)
ENV = {
    "ADMIN_PERMISSION_SETS": "AdministratorAccess,AA-Admin",
    "SAML_REGIONS": "us-east-1,us-west-1",
    "ACTIVITY_REGIONS": "us-east-1,us-west-1",
    "LOOKBACK_HOURS": "36",
    "IDLE_MINUTES": "60",
    "DELIVERY_LAG_MINUTES": "15",
    "MAX_PAGES": "100",
    "ENV_NAME": "dev",
    "RUNBOOK_URL": "https://example.org/runbook",
    "ALERT_TOPIC_ARN": f"arn:aws:sns:us-west-1:{ACCOUNT}:alerts",
    "STATE_BUCKET": "state-bucket",
    "STATE_KEY": "sec-digest/admin-sessions.json",
}


def iso(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def sts_expiration(dt: datetime) -> str:
    """CloudTrail's STS expiration text, e.g. 'Oct 30, 2026, 3:00:00 AM'."""
    return f"{dt:%b} {dt.day}, {dt.year}, {int(dt.strftime('%I'))}:{dt:%M:%S %p}"


def row(ct: dict, resources=None) -> dict:
    """A LookupEvents row as boto3 returns it."""
    ident = ct.get("userIdentity") or {}
    return {
        "EventId": ct["eventID"], "EventName": ct["eventName"], "EventTime": h.parse_time(ct["eventTime"]),
        "EventSource": ct["eventSource"], "ReadOnly": str(ct.get("readOnly", "")).lower(),
        "AccessKeyId": ident.get("accessKeyId", ""),
        "Username": ident.get("userName") or (ident.get("arn", "").rsplit("/", 1)[-1] if ident else ""),
        "Resources": resources or [],
        "CloudTrailEvent": json.dumps(ct),
    }


def saml(eid: str, start: datetime, *, user=USER, role=ADMIN_ROLE, key=CLI_KEY, hours=1, error=None,
         region="us-east-1", expiration=True) -> dict:
    creds = {"accessKeyId": key}
    if expiration:
        creds["expiration"] = sts_expiration(start + timedelta(hours=hours))
    ct = {
        "eventVersion": "1.08", "eventID": eid, "eventName": "AssumeRoleWithSAML", "eventSource": "sts.amazonaws.com",
        "eventTime": iso(start), "awsRegion": region, "sourceIPAddress": "203.0.113.10", "readOnly": True,
        "userIdentity": {"type": "SAMLUser", "userName": user, "principalId": f"EXAMPLE:{user}"},
        "requestParameters": {
            "roleArn": f"arn:aws:iam::{ACCOUNT}:role/aws-reserved/sso.amazonaws.com/{role}",
            "principalArn": f"arn:aws:iam::{ACCOUNT}:saml-provider/AWSSSO_0000_DO_NOT_DELETE",
            "roleSessionName": user, "durationSeconds": hours * 3600,
        },
        "responseElements": None if error else {"credentials": creds},
        "recipientAccountId": ACCOUNT,
    }
    if error:
        ct["errorCode"] = error
    return row(ct)


def call(eid: str, when: datetime, name: str, *, source="s3", read_only=False, user=USER, role=ADMIN_ROLE,
         key=CLI_KEY, created=None, region="us-west-1", error=None, console=False, resources=None, params=None,
         ip="198.51.100.23") -> dict:
    ct = {
        "eventVersion": "1.09", "eventID": eid, "eventName": name, "eventSource": f"{source}.amazonaws.com",
        "eventTime": iso(when), "awsRegion": region, "sourceIPAddress": ip, "readOnly": read_only,
        "userIdentity": {
            "type": "AssumedRole", "principalId": f"AROAEXAMPLE:{user}",
            "arn": f"arn:aws:sts::{ACCOUNT}:assumed-role/{role}/{user}", "accountId": ACCOUNT,
            "accessKeyId": key,
            "sessionContext": {
                "sessionIssuer": {"type": "Role", "userName": role,
                                  "arn": f"arn:aws:iam::{ACCOUNT}:role/aws-reserved/sso.amazonaws.com/{role}"},
                "attributes": {"creationDate": iso(created or T0), "mfaAuthenticated": "false"},
            },
        },
        "requestParameters": params or {},
        "recipientAccountId": ACCOUNT,
    }
    if error:
        ct["errorCode"] = error
    if console:
        ct["sessionCredentialFromConsole"] = "true"
    return row(ct, resources)


class FakeCloudTrail:
    """lookup_events over a fixed list of rows: attribute filter, time window, 50-row pages."""

    def __init__(self, rows=None):
        self.rows = list(rows or [])
        self.calls = []

    def lookup_events(self, LookupAttributes, StartTime, EndTime, MaxResults, NextToken=None):
        attr = LookupAttributes[0]
        self.calls.append((attr["AttributeKey"], attr["AttributeValue"], StartTime, EndTime))
        field = {"EventName": "EventName", "Username": "Username", "AccessKeyId": "AccessKeyId"}[attr["AttributeKey"]]
        hits = [r for r in self.rows if r[field] == attr["AttributeValue"] and StartTime <= r["EventTime"] <= EndTime]
        hits.sort(key=lambda r: r["EventTime"], reverse=True)
        start = int(NextToken or 0)
        page = hits[start:start + MaxResults]
        out = {"Events": page}
        if start + MaxResults < len(hits):
            out["NextToken"] = str(start + MaxResults)
        return out


class FakeSns:
    def __init__(self):
        self.published = []

    def publish(self, TopicArn, Subject, Message):
        self.published.append({"TopicArn": TopicArn, "Subject": Subject, "Message": Message})


class _NoSuchKey(Exception):
    response = {"Error": {"Code": "NoSuchKey"}}


class _Denied(Exception):
    response = {"Error": {"Code": "AccessDenied"}}


class FakeS3:
    def __init__(self, body=None, get_error=None):
        self.body, self.get_error, self.puts = body, get_error, []

    def get_object(self, Bucket, Key):
        if self.get_error:
            raise self.get_error
        if self.body is None:
            raise _NoSuchKey()
        return {"Body": io.BytesIO(self.body)}

    def put_object(self, Bucket, Key, ContentType, Body):
        self.puts.append((Bucket, Key))
        self.body = Body


def clients(east=(), west=()):
    return {"us-east-1": FakeCloudTrail(east), "us-west-1": FakeCloudTrail(west)}


LEAK_PATTERNS = (re.compile(r"(?<!\d)\d{12}(?!\d)"), re.compile(r"arn:"), re.compile(r"@example\.org"),
                 re.compile(re.escape(CLI_KEY)), re.compile(re.escape(CONSOLE_KEY)), re.compile(r"203\.0\.113\.10"))


def assert_clean(test: unittest.TestCase, text: str) -> None:
    for p in LEAK_PATTERNS:
        test.assertNotRegex(text, p)


class MaskTest(unittest.TestCase):
    def test_arn_becomes_resource_name(self):
        cases = {
            f"arn:aws:iam::{ACCOUNT}:role/aws-reserved/sso.amazonaws.com/{ADMIN_ROLE}": ADMIN_ROLE,
            "arn:aws:s3:::invented-bucket/some/key.txt": "invented-bucket/some/key.txt",
            f"arn:aws:lambda:us-west-1:{ACCOUNT}:function:invented-fn": "invented-fn",
            f"arn:aws:logs:us-west-1:{ACCOUNT}:log-group:/aws/lambda/invented-fn:*": "/aws/lambda/invented-fn",
            f"arn:aws:sns:us-west-1:{ACCOUNT}:invented-topic": "invented-topic",
            f"arn:aws:rds:us-west-1:{ACCOUNT}:db:invented-db": "invented-db",
        }
        for arn, name in cases.items():
            with self.subTest(arn=arn):
                self.assertEqual(h.arn_resource_name(arn), name)
                self.assertEqual(h.mask_text(f"x {arn} y"), f"x {name} y")

    def test_account_email_and_arn_never_survive(self):
        text = (f"bucket invented-{ACCOUNT}, owner {USER}, principal arn:aws:sts::{ACCOUNT}:assumed-role/r/{USER} "
                f"and a stray arn: marker")
        out = h.mask_text(text)
        assert_clean(self, out)
        self.assertIn("invented-{account}", out)
        self.assertIn("lan.tester@…", out)

    def test_session_name_local_part_only(self):
        self.assertEqual(h.mask_session_name(USER), "lan.tester")
        self.assertEqual(h.mask_session_name("plainname"), "plainname")
        self.assertEqual(h.mask_session_name(""), "(unnamed)")
        self.assertEqual(h.mask_session_name(f"{ACCOUNT}@example.org"), "{account}")

    def test_ip_mask(self):
        self.assertEqual(h.mask_ip("203.0.113.10"), "203.0.113.x")
        self.assertEqual(h.mask_ip("2001:db8:85a3::8a2e:370:7334"), "2001:0db8:85a3:…")
        self.assertEqual(h.mask_ip("cloudformation.amazonaws.com"), "cloudformation.amazonaws.com")
        self.assertEqual(h.mask_ip(""), "(none)")


class ParseTest(unittest.TestCase):
    def test_times(self):
        self.assertEqual(h.parse_time("2026-10-30T02:00:00Z"), T0)
        self.assertEqual(h.parse_time("Oct 30, 2026, 3:05:09 AM"), T0 + timedelta(hours=1, minutes=5, seconds=9))
        self.assertEqual(h.parse_time("Oct 30, 2026, 1:00:00 PM"), T0 + timedelta(hours=11))
        self.assertIsNone(h.parse_time("soon"))
        self.assertIsNone(h.parse_time(None))

    def test_permission_set_of(self):
        self.assertEqual(h.permission_set_of(ADMIN_ROLE, SETS), "AdministratorAccess")
        self.assertEqual(h.permission_set_of(f"x/us-west-1/{AA_ROLE}", SETS), "AA-Admin")
        self.assertIsNone(h.permission_set_of(DEV_ROLE, SETS))
        self.assertIsNone(h.permission_set_of("aa365-admin-mfa", SETS))

    def test_session_from_saml(self):
        s = h.session_from_saml(saml("e1", T0, hours=2), SETS)
        self.assertEqual((s.permission_set, s.role_name, s.session_name, s.access_key),
                         ("AdministratorAccess", ADMIN_ROLE, USER, CLI_KEY))
        self.assertEqual((s.start, s.expires), (T0, T0 + timedelta(hours=2)))

    def test_session_expiry_fallbacks_and_cap(self):
        s = h.session_from_saml(saml("e1", T0, hours=3, expiration=False), SETS)
        self.assertEqual(s.expires, T0 + timedelta(hours=3))
        s = h.session_from_saml(saml("e2", T0, hours=20), SETS)
        self.assertEqual(s.expires, T0 + timedelta(hours=12))

    def test_non_admin_and_failed_sessions_are_ignored(self):
        self.assertIsNone(h.session_from_saml(saml("e1", T0, role=DEV_ROLE), SETS))
        self.assertIsNone(h.session_from_saml(saml("e2", T0, error="AccessDenied"), SETS))

    def test_activity_resources_and_flags(self):
        a = h.activity_from_lookup(call("c1", T0, "DeleteBucket", resources=[
            {"ResourceType": "AWS::S3::Bucket", "ResourceName": f"invented-{ACCOUNT}"}]))
        self.assertEqual(a.resources, ["invented-{account}"])
        self.assertTrue(a.is_delete)
        a = h.activity_from_lookup(call("c2", T0, "PutRolePolicy", source="iam",
                                        params={"roleName": "invented-role", "policyName": "inline-x"}))
        self.assertEqual(a.resources, ["invented-role", "inline-x"])
        self.assertFalse(a.is_delete)
        self.assertEqual(a.service, "iam")
        a = h.activity_from_lookup(call("c3", T0, "GetObject", read_only=True, params={
            "bucketName": f"arn:aws:s3:::invented-{ACCOUNT}"}))
        self.assertTrue(a.read_only)
        self.assertEqual(a.resources, ["invented-{account}"])

    def test_read_only_flag_missing_falls_back_to_verb(self):
        r = call("c1", T0, "DescribeInstances", source="ec2")
        ct = json.loads(r["CloudTrailEvent"])
        del ct["readOnly"]
        r["CloudTrailEvent"], r["ReadOnly"] = json.dumps(ct), None
        self.assertTrue(h.activity_from_lookup(r).read_only)


class AttributionTest(unittest.TestCase):
    def test_overlapping_console_and_cli_sessions(self):
        console = h.session_from_saml(saml("s-con", T0, key=CONSOLE_KEY), SETS)
        cli = h.session_from_saml(saml("s-cli", T0 + timedelta(minutes=20), key=CLI_KEY), SETS)
        acts = [h.activity_from_lookup(r) for r in (
            call("a1", T0 + timedelta(minutes=25), "ListBuckets", read_only=True, key=CLI_KEY),
            # Console calls carry other keys; their credential creationDate is the console session start.
            call("a2", T0 + timedelta(minutes=26), "ListBuckets", read_only=True, key="KEYOTHERAAAAAAAA",
                 created=T0, console=True),
            call("a3", T0 + timedelta(minutes=27), "PutObject", key="KEYOTHERBBBBBBBB",
                 created=T0 + timedelta(minutes=30)),
        )]
        per = h.attribute(acts, [console, cli])
        self.assertEqual([a.event_id for a in per["s-cli"]], ["a1", "a3"])
        self.assertEqual([a.event_id for a in per["s-con"]], ["a2"])

    def test_group_filter(self):
        keys = {CLI_KEY}
        mine = h.activity_from_lookup(call("a1", T0, "ListBuckets", key="KEYOTHERAAAAAAAA"))
        other_role = h.activity_from_lookup(call("a2", T0, "ListBuckets", role=DEV_ROLE, key="KEYOTHERAAAAAAAA"))
        own_key = h.activity_from_lookup(call("a3", T0, "ListBuckets", role=DEV_ROLE, key=CLI_KEY))
        self.assertTrue(h.belongs_to_group(mine, ADMIN_ROLE, keys))
        self.assertFalse(h.belongs_to_group(other_role, ADMIN_ROLE, keys))
        self.assertTrue(h.belongs_to_group(own_key, ADMIN_ROLE, keys))

    def test_session_end(self):
        s = h.session_from_saml(saml("s1", T0, hours=8), SETS)
        idle, lag = timedelta(minutes=60), timedelta(minutes=15)
        acts = [h.activity_from_lookup(call("a1", T0 + timedelta(minutes=30), "ListBuckets", read_only=True))]
        over, end, why = h.session_end(s, acts, now=T0 + timedelta(minutes=80), idle=idle, lag=lag)
        self.assertFalse(over)
        over, end, why = h.session_end(s, acts, now=T0 + timedelta(minutes=95), idle=idle, lag=lag)
        self.assertTrue(over)
        self.assertEqual(end, T0 + timedelta(minutes=30))
        self.assertIn("no activity", why)
        over, end, why = h.session_end(s, acts, now=T0 + timedelta(hours=8, minutes=15), idle=idle, lag=lag)
        self.assertEqual((over, end, why), (True, T0 + timedelta(hours=8), "credentials expired"))
        over, _, _ = h.session_end(s, [], now=T0 + timedelta(minutes=59), idle=idle, lag=lag)
        self.assertFalse(over)


class DigestTest(unittest.TestCase):
    def setUp(self):
        self.s = h.session_from_saml(saml("s1", T0), SETS)
        self.acts = [h.activity_from_lookup(r) for r in (
            call("a1", T0 + timedelta(minutes=1), "ListBuckets", read_only=True),
            call("a2", T0 + timedelta(minutes=2), "PutBucketPolicy", resources=[
                {"ResourceType": "AWS::S3::Bucket", "ResourceName": f"invented-{ACCOUNT}"}]),
            call("a3", T0 + timedelta(minutes=3), "DeleteRole", source="iam", region="us-east-1",
                 params={"roleName": "invented-role"}, error="AccessDenied"),
            call("a4", T0 + timedelta(minutes=4), "ListBuckets", read_only=True),
            call("a5", T0 + timedelta(minutes=5), "GetCallerIdentity", source="sts", read_only=True,
                 ip="2001:db8::1"),
        )]

    def digest(self, **kw):
        kw.setdefault("end", T0 + timedelta(minutes=5))
        kw.setdefault("reason", "no activity for 60 min")
        return h.build_digest(self.s, self.acts, env_name="dev", regions=["us-east-1", "us-west-1"],
                              runbook_url="https://example.org/runbook", **kw)

    def test_shape_and_order(self):
        subject, msg = self.digest()
        self.assertEqual(subject, "[aa-sec] admin session digest: lan.tester (AdministratorAccess) 2026-10-30 02:00Z")
        self.assertIn("session 'lan.tester' on the AdministratorAccess permission set", msg)
        self.assertIn("Session start: 2026-10-30 02:00Z (09:00 ICT) from 203.0.113.x", msg)
        self.assertIn("Calls: 5 (1 delete, 1 other write, 3 read-only, 1 with an error code; console 0, API 5)", msg)
        i_del, i_wr, i_rd = msg.index("DELETE actions (1)"), msg.index("Other WRITE actions (1)"), \
            msg.index("Read-only calls (3)")
        self.assertLess(i_del, i_wr)
        self.assertLess(i_wr, i_rd)
        self.assertIn("2026-10-30 02:03:00Z  iam:DeleteRole  invented-role [us-east-1]  error: AccessDenied", msg)
        self.assertIn("s3:PutBucketPolicy  invented-{account} [us-west-1]", msg)
        self.assertIn("    2  s3:ListBuckets", msg)
        self.assertIn("Source IPs: 198.51.100.x (4), 2001:0db8:0000:… (1)", msg)
        self.assertTrue(msg.rstrip().endswith("Runbook: https://example.org/runbook"))
        assert_clean(self, subject + msg)

    def test_subject_is_short_ascii(self):
        self.s.session_name = "x" * 200 + "@example.org"
        subject, _ = self.digest(continued_from=T0, preview=True)
        self.assertLessEqual(len(subject), 100)
        subject.encode("ascii")

    def test_empty_session_and_truncation(self):
        self.acts = []
        _, msg = self.digest(truncated=True)
        self.assertIn("No call by this session was found in CloudTrail.", msg)
        self.assertIn("WARNING: the lookup hit its page cap", msg)

    def test_write_lines_are_capped(self):
        self.acts = [h.activity_from_lookup(call(f"w{i}", T0 + timedelta(seconds=i), "PutObject"))
                     for i in range(h.WRITE_LINES_MAX + 7)]
        _, msg = self.digest()
        self.assertIn("... and 7 more write/delete calls", msg)


class RunTest(unittest.TestCase):
    def setUp(self):
        self.sns, self.s3 = FakeSns(), FakeS3()
        start = T0
        self.east = [
            saml("s1", start, hours=1),
            saml("s-dev", start, role=DEV_ROLE, user=OTHER_USER),
            call("a1", start + timedelta(minutes=2), "CreatePolicy", source="iam", region="us-east-1",
                 params={"policyName": "invented-policy"}),
        ]
        self.west = [
            call("a2", start + timedelta(minutes=3), "ListBuckets", read_only=True),
            call("a3", start + timedelta(minutes=4), "DeleteObject", resources=[
                {"ResourceType": "AWS::S3::Object", "ResourceName": "arn:aws:s3:::invented-bucket/a.txt"}]),
            call("x1", start + timedelta(minutes=5), "ListBuckets", read_only=True, user=OTHER_USER, role=DEV_ROLE,
                 key="KEYOTHERAAAAAAAA"),
        ]

    def run_at(self, now, event=None, **kw):
        cl = kw.pop("clients", None) or clients(self.east, self.west)
        return h.run(cl, self.sns, self.s3, env=dict(ENV, **kw.pop("env", {})), now=now, event=event, **kw), cl

    def test_digest_once_then_no_duplicate(self):
        summary, _ = self.run_at(T0 + timedelta(hours=2))
        self.assertEqual((summary["sessions_found"], summary["digests"]), (1, 1))
        self.assertEqual(len(self.sns.published), 1)
        msg = self.sns.published[0]["Message"]
        self.assertIn("Calls: 3 (1 delete, 1 other write, 1 read-only", msg)
        self.assertIn("s3:DeleteObject  invented-bucket/a.txt", msg)
        self.assertIn("iam:CreatePolicy  invented-policy", msg)
        self.assertNotIn("minh.sample", msg)
        assert_clean(self, msg + self.sns.published[0]["Subject"])
        state = json.loads(self.s3.body)
        self.assertEqual(set(state["sessions"]), {"s1"})
        self.assertTrue(state["sessions"]["s1"]["closed"])
        self.assertNotIn("lan.tester", self.s3.body.decode())

        summary, cl = self.run_at(T0 + timedelta(hours=3))
        self.assertEqual(summary["digests"], 0)
        self.assertEqual(len(self.sns.published), 1)
        # A closed session costs no activity lookup.
        self.assertFalse([c for c in cl["us-west-1"].calls if c[0] != "EventName"])

    def test_active_session_waits(self):
        summary, _ = self.run_at(T0 + timedelta(minutes=30))
        self.assertEqual((summary["digests"], summary["waiting"]), (0, 1))
        self.assertEqual(self.sns.published, [])
        self.assertIsNone(self.s3.body)

    def test_idle_close_then_continued_digest(self):
        self.east[0] = saml("s1", T0, hours=8)
        summary, _ = self.run_at(T0 + timedelta(minutes=70))
        self.assertEqual(summary["digests"], 1)
        state = json.loads(self.s3.body)
        self.assertFalse(state["sessions"]["s1"]["closed"])
        # Back after the pause.
        self.west.append(call("a9", T0 + timedelta(hours=3), "TerminateInstances", source="ec2",
                              params={"instanceId": "i-0invented"}))
        summary, _ = self.run_at(T0 + timedelta(hours=3, minutes=30))
        self.assertEqual(summary["waiting"], 1)
        summary, _ = self.run_at(T0 + timedelta(hours=4, minutes=5))
        self.assertEqual(summary["digests"], 1)
        follow = self.sns.published[-1]
        self.assertIn("(continued)", follow["Subject"])
        self.assertIn("Calls: 1 (1 delete", follow["Message"])
        self.assertIn("ec2:TerminateInstances  i-0invented", follow["Message"])
        # Expiry with nothing new: closed without a mail.
        summary, _ = self.run_at(T0 + timedelta(hours=8, minutes=20))
        self.assertEqual((summary["digests"], summary["closed_quietly"]), (0, 1))
        self.assertTrue(json.loads(self.s3.body)["sessions"]["s1"]["closed"])
        self.assertEqual(len(self.sns.published), 2)

    def test_preview_publishes_nothing_and_touches_no_state(self):
        s3 = FakeS3(get_error=_Denied())
        summary = h.run(clients(self.east, self.west), self.sns, s3, env=ENV, now=T0 + timedelta(minutes=10),
                        event={"preview": True, "since": iso(T0 - timedelta(hours=1)),
                               "until": iso(T0 + timedelta(hours=1))})
        self.assertEqual(summary["digests"], 1)
        self.assertEqual(self.sns.published, [])
        self.assertEqual(s3.puts, [])
        self.assertIn("[preview]", summary["messages"][0]["subject"])
        self.assertIn("still open at preview time", summary["messages"][0]["message"])

    def test_preview_needs_a_window(self):
        for bad in ({"since": iso(T0)}, {"since": iso(T0 + timedelta(hours=1)), "until": iso(T0 + timedelta(hours=2))},
                    {"since": iso(T0), "until": iso(T0 - timedelta(hours=1))}):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                h.run(clients(), self.sns, self.s3, env=ENV, now=T0, event={"preview": True, **bad})

    def test_cli_session_found_by_access_key_when_username_lookup_misses(self):
        # Username lookups find nothing (rows carry another Username); the AccessKeyId lookup finds the calls.
        for r in self.east + self.west:
            if r["EventName"] != "AssumeRoleWithSAML":
                r["Username"] = "not-the-session-name"
        summary, cl = self.run_at(T0 + timedelta(hours=2))
        self.assertEqual(summary["digests"], 1)
        self.assertIn("Calls: 3", self.sns.published[0]["Message"])
        self.assertIn(("AccessKeyId", CLI_KEY), [(c[0], c[1]) for c in cl["us-west-1"].calls])

    def test_pagination_and_page_cap(self):
        self.west += [call(f"r{i}", T0 + timedelta(minutes=10, seconds=i), "HeadObject", read_only=True)
                      for i in range(120)]
        summary, _ = self.run_at(T0 + timedelta(hours=2))
        self.assertIn("Calls: 123", self.sns.published[0]["Message"])
        self.sns.published.clear()
        self.s3.body = None
        summary, _ = self.run_at(T0 + timedelta(hours=2), env={"MAX_PAGES": "1"})
        self.assertIn("WARNING: the lookup hit its page cap", self.sns.published[0]["Message"])

    def test_low_time_defers_without_state(self):
        summary, _ = self.run_at(T0 + timedelta(hours=2), time_left=lambda: 30_000)
        self.assertEqual((summary["digests"], summary["deferred"]), (0, 1))
        self.assertIsNone(self.s3.body)

    def test_state_read_error_fails_the_run(self):
        self.s3 = FakeS3(get_error=_Denied())
        with self.assertRaises(_Denied):
            self.run_at(T0 + timedelta(hours=2))
        self.assertEqual(self.sns.published, [])

    def test_old_state_is_pruned(self):
        old = {"version": 1, "sessions": {"gone": {"start": "2026-10-01T00:00:00Z", "expires": "2026-10-01T01:00:00Z",
                                                   "reported_through": "2026-10-01T00:30:00Z", "closed": True}}}
        self.s3.body = json.dumps(old).encode()
        self.run_at(T0 + timedelta(hours=2))
        self.assertEqual(set(json.loads(self.s3.body)["sessions"]), {"s1"})

    def test_config_errors(self):
        for bad in ({"ADMIN_PERMISSION_SETS": ""}, {"ALERT_TOPIC_ARN": ""}, {"STATE_BUCKET": ""},
                    {"LOOKBACK_HOURS": "6"}, {"ACTIVITY_REGIONS": "eu-west-1"}):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                self.run_at(T0, env=bad)


if __name__ == "__main__":
    unittest.main()
