"""AA-878 + AA-816 — unit tests for the ops-probe trigger (lambda_src/dfs_balance_check). No AWS access.

Run from accounts/aa365 (stdlib unittest, no pytest needed):

    python3 -B -m unittest discover -s lambda_src/dfs_balance_check_tests -v

Kept outside lambda_src/dfs_balance_check/ so archive_file never packages the tests (S240 lesson:
bytecode next to handler.py drifts the Lambda source_code_hash).
"""

from __future__ import annotations

import io
import json
import os
import sys
import types
import unittest
import urllib.error
from unittest import mock

sys.dont_write_bytecode = True  # keep __pycache__ out of the archive_file source dir
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "dfs_balance_check"))
os.environ.setdefault("API_BASE_URL", "https://api.example.test/")
os.environ.pop("ADMIN_SECRET", None)

import handler as h  # noqa: E402

SECRET_ARN = "arn:aws:secretsmanager:us-west-1:005097885195:secret:aa-cis/dev/admin-secret-abc123"
RECONCILE = "/admin/job-runner/staff-reconcile/schedule"
RETENTION = "/admin/job-runner/retention/schedule"
PHOTO_SYNC = "/admin/photos/sync/schedule"  # AA-844


class _Resp:
    """Minimal urlopen() context-manager response."""

    def __init__(self, status=200, body=b'{"ok": true}'):
        self.status = status
        self._body = body

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def _fake_boto3(secret_value=None, error=None):
    """A stand-in boto3 module whose secretsmanager client returns secret_value or raises error."""
    client = mock.Mock()
    if error is not None:
        client.get_secret_value.side_effect = error
    else:
        client.get_secret_value.return_value = {"SecretString": secret_value}
    mod = types.ModuleType("boto3")
    mod.client = mock.Mock(return_value=client)
    return mod, client


class SelectPathsTest(unittest.TestCase):
    def test_default_run_includes_staff_reconcile(self):
        self.assertIn(RECONCILE, h._select_paths({}))

    def test_default_run_keeps_existing_probes(self):
        paths = h._select_paths({})
        for p in ("/admin/dfs-balance/check", "/admin/jev-canary/check", "/admin/jev/402-sweep",
                  "/admin/waves/check"):
            self.assertIn(p, paths)
        self.assertNotIn(RETENTION, paths)  # retention runs on its own 20:30 UTC schedule

    def test_on_demand_reconcile_path_allowed(self):
        self.assertEqual(h._select_paths({"paths": [RECONCILE]}), (RECONCILE,))

    def test_retention_path_allowed(self):
        self.assertEqual(h._select_paths({"paths": RETENTION}), (RETENTION,))

    def test_photo_sync_path_allowed(self):
        self.assertEqual(h.PHOTO_SYNC_SCHEDULE_PATH, PHOTO_SYNC)
        self.assertEqual(h._select_paths({"paths": [PHOTO_SYNC]}), (PHOTO_SYNC,))

    def test_photo_sync_not_in_default_run(self):
        # AA-844: photo_sync runs on its own 21:00 UTC schedule, never from the 06:15 probe run.
        self.assertNotIn(PHOTO_SYNC, h._select_paths({}))

    def test_unknown_path_refused_and_duplicates_dropped(self):
        got = h._select_paths({"paths": ["/admin/anything", RECONCILE, RECONCILE, "/auth/admin-login"]})
        self.assertEqual(got, (RECONCILE,))


class SecretByArnTest(unittest.TestCase):
    def test_no_env_fallback_attribute(self):
        self.assertFalse(hasattr(h, "_ENV_SECRET"))

    def test_secret_read_ok_sets_header(self):
        fake, client = _fake_boto3(" s3cret \n")
        with mock.patch.dict(sys.modules, {"boto3": fake}), \
                mock.patch("urllib.request.urlopen", return_value=_Resp()) as urlopen:
            out = h.handler({"paths": [RECONCILE], "secret_id": SECRET_ARN}, None)
        client.get_secret_value.assert_called_once_with(SecretId=SECRET_ARN)
        self.assertEqual(out["statusCode"], 200)
        self.assertEqual(json.loads(out["body"]), {RECONCILE: {"ok": True, "status": 200}})
        req = urlopen.call_args.args[0]
        self.assertEqual(req.full_url, "https://api.example.test" + RECONCILE)
        self.assertEqual(req.get_method(), "POST")
        self.assertEqual(req.get_header("X-admin-secret"), "s3cret")

    def test_no_secret_id_makes_no_http_call(self):
        fake, client = _fake_boto3("s3cret")
        with mock.patch.dict(sys.modules, {"boto3": fake}), \
                mock.patch("urllib.request.urlopen") as urlopen, \
                self.assertLogs(level="ERROR") as logs:
            out = h.handler({"paths": [RECONCILE]}, None)
        urlopen.assert_not_called()
        client.get_secret_value.assert_not_called()
        self.assertEqual(out["statusCode"], 500)
        self.assertEqual(json.loads(out["body"]), {"error": "admin_secret_unavailable"})
        self.assertTrue(any("admin_secret_unavailable" in line for line in logs.output))

    def test_no_secret_id_even_with_env_admin_secret(self):
        # A leftover ADMIN_SECRET env (old deploy) must not be used.
        fake, _ = _fake_boto3("s3cret")
        with mock.patch.dict(os.environ, {"ADMIN_SECRET": "stale"}), \
                mock.patch.dict(sys.modules, {"boto3": fake}), \
                mock.patch("urllib.request.urlopen") as urlopen, \
                self.assertLogs(level="ERROR"):
            out = h.handler({}, None)
        urlopen.assert_not_called()
        self.assertEqual(out["statusCode"], 500)

    def test_read_error_makes_no_http_call(self):
        fake, _ = _fake_boto3(error=RuntimeError("AccessDeniedException"))
        with mock.patch.dict(sys.modules, {"boto3": fake}), \
                mock.patch("urllib.request.urlopen") as urlopen, \
                self.assertLogs(level="ERROR") as logs:
            out = h.handler({"secret_id": SECRET_ARN}, None)
        urlopen.assert_not_called()
        self.assertEqual(out["statusCode"], 500)
        self.assertTrue(any("secret_read_failed" in line for line in logs.output))
        self.assertTrue(any("admin_secret_unavailable" in line for line in logs.output))

    def test_empty_secret_value_makes_no_http_call(self):
        fake, _ = _fake_boto3("   ")
        with mock.patch.dict(sys.modules, {"boto3": fake}), \
                mock.patch("urllib.request.urlopen") as urlopen, \
                self.assertLogs(level="ERROR"):
            out = h.handler({"secret_id": SECRET_ARN}, None)
        urlopen.assert_not_called()
        self.assertEqual(out["statusCode"], 500)

    def test_only_refused_paths_makes_no_http_call(self):
        fake, _ = _fake_boto3("s3cret")
        with mock.patch.dict(sys.modules, {"boto3": fake}), \
                mock.patch("urllib.request.urlopen") as urlopen, \
                self.assertLogs(level="ERROR"):
            out = h.handler({"paths": ["/admin/anything"], "secret_id": SECRET_ARN}, None)
        urlopen.assert_not_called()
        self.assertEqual(out["statusCode"], 502)
        self.assertEqual(json.loads(out["body"]), {})


class PostResultsTest(unittest.TestCase):
    def test_one_failing_path_does_not_stop_the_rest(self):
        def urlopen(req, timeout=None):
            if req.full_url.endswith("/admin/jev-canary/check"):
                raise urllib.error.HTTPError(req.full_url, 402, "Payment Required", {},
                                             io.BytesIO(b"credit"))
            return _Resp()

        fake, _ = _fake_boto3("s3cret")
        with mock.patch.dict(sys.modules, {"boto3": fake}), \
                mock.patch("urllib.request.urlopen", side_effect=urlopen) as uo, \
                self.assertLogs(level="INFO"):
            out = h.handler({"secret_id": SECRET_ARN}, None)
        self.assertEqual(uo.call_count, len(h._PATHS))
        body = json.loads(out["body"])
        self.assertEqual(body["/admin/jev-canary/check"], {"ok": False, "status": 402})
        self.assertEqual(body[RECONCILE], {"ok": True, "status": 200})
        self.assertEqual(out["statusCode"], 200)

    def test_all_paths_down_is_502(self):
        fake, _ = _fake_boto3("s3cret")
        with mock.patch.dict(sys.modules, {"boto3": fake}), \
                mock.patch("urllib.request.urlopen", side_effect=OSError("timeout")), \
                self.assertLogs(level="ERROR"):
            out = h.handler({"paths": [RECONCILE], "secret_id": SECRET_ARN}, None)
        self.assertEqual(out["statusCode"], 502)
        self.assertEqual(json.loads(out["body"]), {RECONCILE: {"ok": False, "status": None}})


if __name__ == "__main__":
    unittest.main()
