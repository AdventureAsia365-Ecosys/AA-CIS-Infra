"""Unit tests for db/check_migration_copies.py (AA-807). No network: the owner repo is a dict.

Run: python3 -m unittest discover -s db/tests -v
"""
import io
import sys
import tempfile
import unittest
import urllib.error
from unittest import mock
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import check_migration_copies as guard  # noqa: E402

CIS_228 = b"""-- 228: views
BEGIN;
CREATE VIEW catalog.v_x AS SELECT 1;
INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('228', now(), 'AA-712: catalog views')
ON CONFLICT (version) DO NOTHING;
COMMIT;
"""

BK_007 = b"""BEGIN;
INSERT INTO booking.fx_rates (code, rate) VALUES ('EUR', 1.1);
INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-007', now(), 'AA-810: fx write')
ON CONFLICT (version) DO NOTHING;
COMMIT;
"""

TP_007 = b"""BEGIN;
DO $$ BEGIN
  IF true THEN
    INSERT INTO shared.schema_versions (version, applied_at, description)
    VALUES ('tp-001', now(), 'backfill') ON CONFLICT (version) DO NOTHING;
  END IF;
END $$;
INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('tp-007', now(), 'register') ON CONFLICT (version) DO NOTHING;
COMMIT;
"""


class FakeOwnerRepos:
    """Owner repos' main, keyed by (repo, path). Missing key = 404 (not merged yet)."""

    def __init__(self, files=None):
        self.files = dict(files or {})
        self.calls = []

    def __call__(self, repo, path):
        self.calls.append((repo, path))
        return self.files.get((repo, path))


class GuardTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def write(self, rel, data):
        p = self.root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)
        return rel

    def check(self, rel, fetch):
        return guard.check_file(rel, self.root, fetch)

    # ── byte compare ────────────────────────────────────────────────────────────

    def test_identical_copy_passes_and_reads_owner_path(self):
        rel = self.write("db/migrations/cis/228_catalog_views.sql", CIS_228)
        fetch = FakeOwnerRepos({("AA-CIS-App", "api/migrations/228_catalog_views.sql"): CIS_228})
        self.assertEqual(self.check(rel, fetch), [])
        self.assertEqual(fetch.calls, [("AA-CIS-App", "api/migrations/228_catalog_views.sql")])

    def test_one_changed_byte_fails(self):
        changed = CIS_228.replace(b"SELECT 1", b"SELECT 2")
        rel = self.write("db/migrations/cis/228_catalog_views.sql", changed)
        fetch = FakeOwnerRepos({("AA-CIS-App", "api/migrations/228_catalog_views.sql"): CIS_228})
        errors = self.check(rel, fetch)
        self.assertEqual(len(errors), 1)
        self.assertIn("differs from AdventureAsia365-Ecosys/AA-CIS-App@main", errors[0])
        self.assertIn("line 3", errors[0])

    def test_trailing_newline_difference_fails(self):
        rel = self.write("db/migrations/cis/228_catalog_views.sql", CIS_228 + b"\n")
        fetch = FakeOwnerRepos({("AA-CIS-App", "api/migrations/228_catalog_views.sql"): CIS_228})
        errors = self.check(rel, fetch)
        self.assertEqual(len(errors), 1)
        self.assertIn("prefix of the other", errors[0])

    def test_crlf_copy_fails(self):
        rel = self.write("db/migrations/cis/228_catalog_views.sql", CIS_228.replace(b"\n", b"\r\n"))
        fetch = FakeOwnerRepos({("AA-CIS-App", "api/migrations/228_catalog_views.sql"): CIS_228})
        self.assertEqual(len(self.check(rel, fetch)), 1)

    def test_owner_file_not_on_main_says_merge_owner_first(self):
        rel = self.write("db/migrations/booking/007_fx_write.sql", BK_007)
        errors = self.check(rel, FakeOwnerRepos())
        self.assertEqual(len(errors), 1)
        self.assertIn("merge the migration-only PR in the owner repo first", errors[0])
        self.assertIn("AA-Booking@main:migrations/007_fx_write.sql", errors[0])

    # ── path and version key ────────────────────────────────────────────────────

    def test_unknown_owner_dir_fails_without_fetch(self):
        rel = self.write("db/migrations/acp/228_x.sql", CIS_228)
        fetch = FakeOwnerRepos()
        errors = self.check(rel, fetch)
        self.assertIn("path must be", errors[0])
        self.assertEqual(fetch.calls, [])

    def test_bad_filename_fails(self):
        for name in ("228-catalog.sql", "0228_catalog.sql", "228_Catalog.sql", "228_catalog.txt"):
            rel = self.write(f"db/migrations/cis/{name}", CIS_228)
            self.assertIn("path must be", self.check(rel, FakeOwnerRepos())[0], name)

    def test_booking_file_registering_unprefixed_key_fails(self):
        body = BK_007.replace(b"'bk-007'", b"'007'")
        rel = self.write("db/migrations/booking/007_fx_write.sql", body)
        fetch = FakeOwnerRepos({("AA-Booking", "migrations/007_fx_write.sql"): body})
        errors = self.check(rel, fetch)
        self.assertTrue(any("does not register its version 'bk-007'" in e for e in errors), errors)
        self.assertTrue(any("outside the booking key prefix bk-NNN" in e for e in errors), errors)

    def test_cis_file_registering_prefixed_key_fails(self):
        body = CIS_228.replace(b"'228'", b"'tp-228'")
        rel = self.write("db/migrations/cis/228_catalog_views.sql", body)
        fetch = FakeOwnerRepos({("AA-CIS-App", "api/migrations/228_catalog_views.sql"): body})
        errors = self.check(rel, fetch)
        self.assertTrue(any("NNN (no prefix)" in e for e in errors), errors)

    def test_version_number_must_match_filename(self):
        body = CIS_228.replace(b"'228'", b"'229'")
        rel = self.write("db/migrations/cis/228_catalog_views.sql", body)
        fetch = FakeOwnerRepos({("AA-CIS-App", "api/migrations/228_catalog_views.sql"): body})
        self.assertIn("does not register its version '228'", self.check(rel, fetch)[0])

    def test_missing_registration_fails(self):
        body = b"BEGIN;\nSELECT 1;\nCOMMIT;\n"
        rel = self.write("db/migrations/cis/228_catalog_views.sql", body)
        fetch = FakeOwnerRepos({("AA-CIS-App", "api/migrations/228_catalog_views.sql"): body})
        self.assertIn("found: none", self.check(rel, fetch)[0])

    def test_other_tables_values_are_ignored_and_backfill_rows_allowed(self):
        rel = self.write("db/migrations/booking/007_fx_write.sql", BK_007)
        fetch = FakeOwnerRepos({("AA-Booking", "migrations/007_fx_write.sql"): BK_007})
        self.assertEqual(self.check(rel, fetch), [])
        rel = self.write("db/migrations/tripplanner/007_register_versions.sql", TP_007)
        fetch = FakeOwnerRepos({("AA-TripPlanner-Web", "migrations/007_register_versions.sql"): TP_007})
        self.assertEqual(self.check(rel, fetch), [])
        self.assertEqual(guard.registered_keys(TP_007.decode()), ["tp-001", "tp-007"])

    # ── roles/ (X1, Infra-native) ──────────────────────────────────────────────

    def test_roles_file_is_native_no_owner_fetch(self):
        body = CIS_228.replace(b"'228'", b"'rl-001'")
        rel = self.write("db/migrations/roles/001_x1_owner_roles.sql", body)
        fetch = FakeOwnerRepos()
        self.assertEqual(self.check(rel, fetch), [])
        self.assertEqual(fetch.calls, [])

    def test_roles_file_needs_its_rl_key(self):
        rel = self.write("db/migrations/roles/002_x1_cis_owner.sql", CIS_228.replace(b"'228'", b"'rl-001'"))
        errors = self.check(rel, FakeOwnerRepos())
        self.assertIn("does not register its version 'rl-002'", errors[0])
        rel = self.write("db/migrations/roles/003_x.sql", CIS_228.replace(b"'228'", b"'003'"))
        errors = self.check(rel, FakeOwnerRepos())
        self.assertTrue(any("outside the roles key prefix rl-NNN" in e for e in errors), errors)

    def test_roles_path_shape(self):
        rel = self.write("db/migrations/roles/01_x.sql", CIS_228)
        self.assertIn("<cis|tripplanner|booking|roles>", self.check(rel, FakeOwnerRepos())[0])

    # ── GitHub errors ───────────────────────────────────────────────────────────

    def test_fetch_error_is_a_fail_and_the_run_continues(self):
        self.write("db/migrations/cis/228_catalog_views.sql", CIS_228)
        self.write("db/migrations/booking/007_fx_write.sql", BK_007)

        def flaky(repo, path):
            if repo == "AA-CIS-App":
                raise guard.FetchError("could not read AA-CIS-App:x from GitHub: HTTP 403")
            return BK_007

        out = io.StringIO()
        paths = ["db/migrations/cis/228_catalog_views.sql", "db/migrations/booking/007_fx_write.sql"]
        self.assertEqual(guard.run(paths, self.root, flaky, out=out), 1)
        self.assertIn("FAIL  db/migrations/cis/228_catalog_views.sql: cannot compare", out.getvalue())
        self.assertIn("ok    db/migrations/booking/007_fx_write.sql", out.getvalue())
        self.assertIn("2 file(s) checked, 1 failed", out.getvalue())

    def _http(self, code):
        return urllib.error.HTTPError("https://api.github.com/x", code, "err", {}, None)

    def _urlopen(self, outcomes, seen):
        def fake(req, timeout=None):
            seen.append(req.get_header("Authorization"))
            item = outcomes.pop(0)
            if isinstance(item, Exception):
                raise item
            cm = mock.MagicMock()
            cm.__enter__.return_value.read.return_value = item
            return cm
        return fake

    def test_github_fetch_404_token_fallback_and_retry(self):
        env = {"GITHUB_TOKEN": "t0k", "GH_TOKEN": ""}
        with mock.patch.dict("os.environ", env), mock.patch.object(guard.time, "sleep"):
            seen = []
            with mock.patch.object(guard.urllib.request, "urlopen", self._urlopen([self._http(404)], seen)):
                self.assertIsNone(guard.github_fetch("AA-CIS-App", "api/migrations/228_x.sql"))

            seen = []   # token refused → anonymous retry succeeds
            outcomes = [self._http(403), b"sql"]
            with mock.patch.object(guard.urllib.request, "urlopen", self._urlopen(outcomes, seen)):
                self.assertEqual(guard.github_fetch("AA-CIS-App", "p"), b"sql")
            self.assertEqual(seen, ["Bearer t0k", None])

            seen = []   # 5xx then success on the next round
            outcomes = [self._http(502), b"sql"]
            with mock.patch.object(guard.urllib.request, "urlopen", self._urlopen(outcomes, seen)):
                self.assertEqual(guard.github_fetch("AA-CIS-App", "p"), b"sql")

            seen = []   # always rate limited → FetchError, not a traceback
            outcomes = [self._http(403)] * 6
            with mock.patch.object(guard.urllib.request, "urlopen", self._urlopen(outcomes, seen)):
                with self.assertRaises(guard.FetchError):
                    guard.github_fetch("AA-CIS-App", "p")
            self.assertEqual(len(seen), 6)


    # ── CLI ─────────────────────────────────────────────────────────────────────

    def test_main_all_exit_codes_and_deleted_files(self):
        self.write("db/migrations/cis/228_catalog_views.sql", CIS_228)
        self.write("db/migrations/booking/007_fx_write.sql", BK_007)
        good = FakeOwnerRepos({
            ("AA-CIS-App", "api/migrations/228_catalog_views.sql"): CIS_228,
            ("AA-Booking", "migrations/007_fx_write.sql"): BK_007,
        })
        args = ["--all", "--repo-root", str(self.root)]
        self.assertEqual(guard.main(args, fetch=good), 0)

        out = io.StringIO()
        paths = ["db/migrations/cis/228_catalog_views.sql", "db/migrations/cis/100_gone.sql"]
        self.assertEqual(guard.run(paths, self.root, FakeOwnerRepos(), out=out), 1)
        self.assertIn("skip  db/migrations/cis/100_gone.sql", out.getvalue())
        self.assertIn("1 file(s) checked, 1 failed", out.getvalue())

    def test_main_no_paths_is_noop(self):
        self.assertEqual(guard.main(["--repo-root", str(self.root)], fetch=FakeOwnerRepos()), 0)


if __name__ == "__main__":
    unittest.main()
