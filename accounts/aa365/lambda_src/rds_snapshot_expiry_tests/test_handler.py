"""AA-869 — unit tests for the RDS manual-snapshot expiry rule. No AWS access.

Run from accounts/aa365 (stdlib unittest, no pytest needed):

    python3 -B -m unittest discover -s lambda_src/rds_snapshot_expiry_tests -v

Kept outside lambda_src/rds_snapshot_expiry/ so archive_file never packages the tests.
"""

from __future__ import annotations

import os
import sys
import unittest
from datetime import datetime, timedelta, timezone

sys.dont_write_bytecode = True  # keep __pycache__ out of the archive_file source dir
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "rds_snapshot_expiry"))

import handler as h  # noqa: E402

NOW = datetime(2026, 10, 17, 22, 0, 0, tzinfo=timezone.utc)
ALLOW = ["aa-cis-dev-db"]


def snap(ident, *, age=None, created=None, tags=None, instance="aa-cis-dev-db", stype="manual",
         status="available"):
    if created is None:
        created = NOW - (age if isinstance(age, timedelta) else timedelta(days=age))
    return {
        "DBSnapshotIdentifier": ident,
        "DBInstanceIdentifier": instance,
        "SnapshotCreateTime": created,
        "SnapshotType": stype,
        "Status": status,
        "DBSnapshotArn": f"arn:aws:rds:us-west-1:005097885195:snapshot:{ident}",
        "TagList": [{"Key": k, "Value": v} for k, v in (tags or {}).items()],
    }


def decide(s, retain_days=30):
    return h.decide_one(s, now=NOW, retain_days=retain_days, allowlist=ALLOW)


class DecideOneTest(unittest.TestCase):
    def test_keep_prefix_kept_even_when_old(self):
        d = decide(snap("keep-g0-audit", age=400))
        self.assertEqual(d.decision, h.KEEP)
        self.assertIn("keep-", d.reason)

    def test_retain_until_future_kept(self):
        d = decide(snap("old", age=90, tags={"aa:retain-until": "2026-12-31"}))
        self.assertEqual(d.decision, h.KEEP)

    def test_retain_until_today_kept(self):
        d = decide(snap("old", age=90, tags={"aa:retain-until": "2026-10-17"}))
        self.assertEqual(d.decision, h.KEEP)

    def test_retain_until_past_expires_even_when_young(self):
        d = decide(snap("young", age=2, tags={"aa:retain-until": "2026-10-16"}))
        self.assertEqual(d.decision, h.EXPIRE)
        self.assertIn("in the past", d.reason)

    def test_retain_until_malformed_kept_and_flagged(self):
        for bad in ("2026-13-01", "17/10/2026", "2026-10-1", "", "soon", " 2026-11-01"):
            with self.subTest(bad=bad):
                d = decide(snap("old", age=90, tags={"aa:retain-until": bad}))
                self.assertEqual(d.decision, h.KEEP)
                self.assertTrue(d.malformed_tag)

    def test_malformed_flag_reported_even_when_kept_by_prefix(self):
        d = decide(snap("keep-x", age=90, tags={"aa:retain-until": "nope"}))
        self.assertEqual(d.decision, h.KEEP)
        self.assertTrue(d.malformed_tag)

    def test_aa_retain_keep(self):
        for value in ("keep", "Keep", " KEEP "):
            with self.subTest(value=value):
                self.assertEqual(decide(snap("old", age=90, tags={"aa:retain": value})).decision, h.KEEP)

    def test_aa_retain_keep_beats_past_retain_until(self):
        d = decide(snap("old", age=90, tags={"aa:retain": "keep", "aa:retain-until": "2026-01-01"}))
        self.assertEqual(d.decision, h.KEEP)

    def test_aa_retain_other_value_does_not_keep(self):
        self.assertEqual(decide(snap("old", age=90, tags={"aa:retain": "yes"})).decision, h.EXPIRE)

    def test_age_29_days_kept(self):
        self.assertEqual(decide(snap("s", age=29)).decision, h.KEEP)

    def test_age_exactly_30_days_kept(self):
        # "older than RETAIN_DAYS" is strict: exactly 30 days is not older.
        self.assertEqual(decide(snap("s", age=30)).decision, h.KEEP)

    def test_age_30_days_and_a_second_expires(self):
        self.assertEqual(decide(snap("s", age=timedelta(days=30, seconds=1))).decision, h.EXPIRE)

    def test_age_31_days_expires(self):
        d = decide(snap("s", age=31))
        self.assertEqual(d.decision, h.EXPIRE)
        self.assertEqual(d.age_days, 31.0)

    def test_retain_days_is_honoured(self):
        self.assertEqual(decide(snap("s", age=31), retain_days=60).decision, h.KEEP)

    def test_automated_snapshot_ignored(self):
        d = decide(snap("rds:aa-cis-dev-db-2026-08-01-03-10", age=90, stype="automated"))
        self.assertEqual(d.decision, h.SKIP)

    def test_shared_public_awsbackup_types_ignored(self):
        for stype in ("shared", "public", "awsbackup"):
            with self.subTest(stype=stype):
                self.assertEqual(decide(snap("x", age=90, stype=stype)).decision, h.SKIP)

    def test_foreign_prefix_ignored_even_if_type_says_manual(self):
        self.assertEqual(decide(snap("awsbackup:job-1", age=90)).decision, h.SKIP)
        self.assertEqual(decide(snap("rds:x", age=90)).decision, h.SKIP)

    def test_non_allowlisted_instance_ignored(self):
        d = decide(snap("other", age=90, instance="aa-booking-dev-db"))
        self.assertEqual(d.decision, h.SKIP)
        self.assertIn("allowlist", d.reason)

    def test_not_available_ignored(self):
        self.assertEqual(decide(snap("s", age=90, status="creating")).decision, h.SKIP)

    def test_string_create_time_parsed(self):
        s = snap("s", created="2026-09-01T00:00:00Z")
        self.assertEqual(decide(s).decision, h.EXPIRE)


class CapAndModeTest(unittest.TestCase):
    def _five_old(self):
        return [snap(f"s{i}", age=40 + i) for i in range(5)]  # s4 oldest

    def test_cap_dry_run_marks_oldest_would_delete_rest_over_cap(self):
        ds = h.plan(self._five_old(), now=NOW, retain_days=30, allowlist=ALLOW, max_deletes=3, dry_run=True)
        by = {d.identifier: d.decision for d in ds}
        self.assertEqual([by[f"s{i}"] for i in (4, 3, 2)], [h.WOULD_DELETE] * 3)
        self.assertEqual([by[f"s{i}"] for i in (1, 0)], [h.OVER_CAP] * 2)

    def test_cap_live_leaves_expire_for_caller(self):
        ds = h.plan(self._five_old(), now=NOW, retain_days=30, allowlist=ALLOW, max_deletes=3, dry_run=False)
        self.assertEqual(sum(d.decision == h.EXPIRE for d in ds), 3)
        self.assertEqual(sum(d.decision == h.OVER_CAP for d in ds), 2)

    def test_cap_zero_deletes_nothing(self):
        ds = h.plan(self._five_old(), now=NOW, retain_days=30, allowlist=ALLOW, max_deletes=0, dry_run=False)
        self.assertTrue(all(d.decision == h.OVER_CAP for d in ds))


class DryRunSemanticsTest(unittest.TestCase):
    def test_only_exact_false_is_live(self):
        self.assertFalse(h.is_dry_run("false"))
        for value in (None, "", "False", "FALSE", "0", "no", " false", "false ", "true"):
            with self.subTest(value=value):
                self.assertTrue(h.is_dry_run(value))


class FakeRds:
    def __init__(self, snapshots, fail=()):
        self.snapshots = snapshots
        self.fail = set(fail)
        self.deleted = []

    def get_paginator(self, name):
        assert name == "describe_db_snapshots"
        outer = self

        class P:
            def paginate(self, **kwargs):
                assert kwargs == {"SnapshotType": "manual", "IncludeShared": False, "IncludePublic": False}
                yield {"DBSnapshots": outer.snapshots}

        return P()

    def list_tags_for_resource(self, ResourceName):  # noqa: N803 — boto3 kwarg
        return {"TagList": []}

    def delete_db_snapshot(self, DBSnapshotIdentifier):  # noqa: N803 — boto3 kwarg
        if DBSnapshotIdentifier in self.fail:
            raise RuntimeError("InvalidDBSnapshotState")
        self.deleted.append(DBSnapshotIdentifier)
        return {}


class FakeSns:
    def __init__(self):
        self.published = []

    def publish(self, **kwargs):
        self.published.append(kwargs)
        return {"MessageId": "m"}


ENV = {
    "RETAIN_DAYS": "30",
    "MAX_DELETES_PER_RUN": "3",
    "INSTANCE_ALLOWLIST": "aa-cis-dev-db",
    "ALERT_TOPIC_ARN": "arn:aws:sns:us-west-1:005097885195:aa-cis-dev-acp-alerts",
    "ENV_NAME": "dev",
}


class RunTest(unittest.TestCase):
    def _run(self, snapshots, dry_run_value, fail=()):
        rds, sns = FakeRds(snapshots, fail), FakeSns()
        env = dict(ENV)
        if dry_run_value is not None:
            env["DRY_RUN"] = dry_run_value
        return rds, sns, env

    def test_dry_run_never_deletes_but_notifies(self):
        for value in (None, "true", "False", ""):
            with self.subTest(value=value):
                rds, sns, env = self._run([snap("old", age=40)], value)
                summary = h.run(rds, sns, env=env, now=NOW)
                self.assertEqual(rds.deleted, [])
                self.assertTrue(summary["dry_run"])
                self.assertEqual(len(sns.published), 1)
                self.assertIn("DRY RUN", sns.published[0]["Subject"])
                self.assertIn("old", sns.published[0]["Message"])

    def test_live_deletes_up_to_cap(self):
        snaps = [snap(f"s{i}", age=40 + i) for i in range(5)] + [snap("young", age=3)]
        rds, sns, env = self._run(snaps, "false")
        summary = h.run(rds, sns, env=env, now=NOW)
        self.assertEqual(rds.deleted, ["s4", "s3", "s2"])
        self.assertEqual(summary["counts"], {h.DELETED: 3, h.OVER_CAP: 2, h.KEEP: 1})
        self.assertEqual(len(sns.published), 1)
        self.assertLessEqual(len(sns.published[0]["Subject"]), 100)

    def test_nothing_to_report_publishes_nothing(self):
        rds, sns, env = self._run([snap("young", age=3), snap("keep-x", age=300)], "false")
        h.run(rds, sns, env=env, now=NOW)
        self.assertEqual(rds.deleted, [])
        self.assertEqual(sns.published, [])

    def test_malformed_tag_alone_publishes(self):
        rds, sns, env = self._run([snap("young", age=3, tags={"aa:retain-until": "later"})], "false")
        summary = h.run(rds, sns, env=env, now=NOW)
        self.assertEqual(rds.deleted, [])
        self.assertEqual(summary["malformed_tags"], ["young"])
        self.assertEqual(len(sns.published), 1)

    def test_delete_failure_reports_then_raises(self):
        rds, sns, env = self._run([snap("a", age=50), snap("b", age=40)], "false", fail={"a"})
        with self.assertRaises(RuntimeError):
            h.run(rds, sns, env=env, now=NOW)
        self.assertEqual(rds.deleted, ["b"])
        self.assertEqual(len(sns.published), 1)
        self.assertIn("error: a", sns.published[0]["Message"])

    def test_bad_config_raises(self):
        for key, value in (("RETAIN_DAYS", "0"), ("RETAIN_DAYS", "x"), ("MAX_DELETES_PER_RUN", "-1"),
                           ("INSTANCE_ALLOWLIST", " , ")):
            with self.subTest(key=key, value=value):
                rds, sns, env = self._run([snap("old", age=40)], "false")
                env[key] = value
                with self.assertRaises(ValueError):
                    h.run(rds, sns, env=env, now=NOW)
                self.assertEqual(rds.deleted, [])

    def test_creating_snapshot_without_create_time_does_not_break_live_run(self):
        creating = snap("in-progress", age=0, status="creating")
        del creating["SnapshotCreateTime"]
        rds, sns, env = self._run([creating, snap("old", age=40)], "false")
        summary = h.run(rds, sns, env=env, now=NOW)
        self.assertEqual(rds.deleted, ["old"])
        self.assertEqual(summary["counts"], {h.SKIP: 1, h.DELETED: 1})

    def test_non_allowlisted_and_automated_never_deleted_live(self):
        snaps = [
            snap("other-db-snap", age=90, instance="aa-booking-dev-db"),
            snap("rds:aa-cis-dev-db-2026-10-10", age=90, stype="automated"),
        ]
        rds, sns, env = self._run(snaps, "false")
        h.run(rds, sns, env=env, now=NOW)
        self.assertEqual(rds.deleted, [])
        self.assertEqual(sns.published, [])


if __name__ == "__main__":
    unittest.main()
