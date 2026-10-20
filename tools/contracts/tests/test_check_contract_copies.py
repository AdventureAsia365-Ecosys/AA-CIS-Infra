"""Unit tests of tools/contracts/check_contract_copies.py (AA-826, X7). Offline: fake GitHub readers and temp dirs.

Run: python3 -m unittest discover -s tools/contracts/tests -v
"""
import copy
import hashlib
import io
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import check_contract_copies as g  # noqa: E402

A = b'{"$id": "inquiry.submitted.v1.json", "type": "object"}\n'
B = b'{"$id": "catalog.tour.v1.json", "type": "object"}\n'


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


MANIFEST = {
    "version": 1,
    "org": "Org",
    "branch": "main",
    "consumer_repos": ["Consumer", "Producer"],
    "contracts": {
        "inquiry.submitted.v1.json": {"sha256": sha(A), "copies": [
            {"repo": "Consumer", "path": "app/contracts/inquiry.submitted.v1.json"}]},
        "catalog.tour.v1.json": {"sha256": sha(B), "copies": [
            {"repo": "Producer", "path": "tests/contracts/catalog.tour.v1.json"}]},
    },
}


class FakeGitHub:
    """files[(repo, ref)] = {path: bytes}; records every (repo, path, ref) read."""

    def __init__(self, files):
        self.files = files
        self.reads = []

    def fetch(self, repo, path, ref):
        self.reads.append((repo, path, ref))
        return self.files.get((repo, ref), {}).get(path)

    def list_files(self, repo, ref):
        if (repo, ref) not in self.files:
            raise g.FetchError(f"ref {ref} not found")
        return list(self.files[(repo, ref)])


def good_files():
    return {("Consumer", "main"): {"app/contracts/inquiry.submitted.v1.json": A, "README.md": b"x"},
            ("Producer", "main"): {"tests/contracts/catalog.tour.v1.json": B}}


def run(manifest, gh, refs=None, canonical_dir=None):
    out = io.StringIO()
    code = g.run(manifest, gh.fetch, gh.list_files, refs or {}, canonical_dir=canonical_dir, out=out)
    return code, out.getvalue()


class CopiesTest(unittest.TestCase):
    def test_green_when_every_copy_matches_its_pin(self):
        code, log = run(MANIFEST, FakeGitHub(good_files()))
        self.assertEqual(code, 0, log)
        self.assertIn("0 failure(s)", log)

    def test_red_on_a_modified_consumer_copy(self):
        files = good_files()
        files[("Consumer", "main")]["app/contracts/inquiry.submitted.v1.json"] = A.replace(b"object", b"objekt")
        code, log = run(MANIFEST, FakeGitHub(files))
        self.assertEqual(code, 1)
        self.assertIn("Consumer@main:app/contracts/inquiry.submitted.v1.json: modified copy of "
                      "inquiry.submitted.v1.json", log)
        self.assertIn("1 failure(s)", log)

    def test_red_on_a_one_byte_change_trailing_newline(self):
        files = good_files()
        files[("Producer", "main")]["tests/contracts/catalog.tour.v1.json"] = B.rstrip(b"\n")
        code, log = run(MANIFEST, FakeGitHub(files))
        self.assertEqual(code, 1)
        self.assertIn("modified copy of catalog.tour.v1.json", log)

    def test_red_when_a_registered_copy_is_missing(self):
        files = good_files()
        del files[("Consumer", "main")]["app/contracts/inquiry.submitted.v1.json"]
        code, log = run(MANIFEST, FakeGitHub(files))
        self.assertEqual(code, 1)
        self.assertIn("registered copy of inquiry.submitted.v1.json not found", log)

    def test_red_on_an_unregistered_copy_of_a_pinned_contract(self):
        files = good_files()
        files[("Consumer", "main")]["web/schemas/catalog.tour.v1.json"] = B     # equal bytes, still unguarded
        code, log = run(MANIFEST, FakeGitHub(files))
        self.assertEqual(code, 1)
        self.assertIn("Consumer@main:web/schemas/catalog.tour.v1.json: unregistered copy of catalog.tour.v1.json",
                      log)

    def test_contract_shaped_unknown_file_is_a_warning(self):
        files = good_files()
        files[("Producer", "main")]["contracts/trip_case.status_changed.v1.json"] = b"{}"
        code, log = run(MANIFEST, FakeGitHub(files))
        self.assertEqual(code, 0, log)
        self.assertIn("WARN  Producer@main:contracts/trip_case.status_changed.v1.json", log)

    def test_ref_override_reads_that_ref_for_that_repo_only(self):
        files = good_files()
        files[("Consumer", "test/red")] = {"app/contracts/inquiry.submitted.v1.json": A + b" "}
        gh = FakeGitHub(files)
        code, log = run(MANIFEST, gh, refs={"Consumer": "test/red"})
        self.assertEqual(code, 1)
        self.assertIn("Consumer@test/red:app/contracts/inquiry.submitted.v1.json: modified copy", log)
        self.assertIn(("Producer", "tests/contracts/catalog.tour.v1.json", "main"), gh.reads)

    def test_fetch_error_is_a_failure_not_a_traceback(self):
        class Broken(FakeGitHub):
            def fetch(self, repo, path, ref):
                raise g.FetchError("HTTP 502")
        code, log = run(MANIFEST, Broken(good_files()))
        self.assertEqual(code, 1)
        self.assertIn("cannot read: HTTP 502", log)


class ManifestTest(unittest.TestCase):
    def errors(self, m):
        r = g.Report()
        g.check_manifest(m, r)
        return r.errors

    def test_committed_manifest_is_valid(self):
        m = g.load_manifest()
        self.assertEqual(self.errors(m), [])
        self.assertEqual(m["consumer_repos"], sorted(m["consumer_repos"]))
        self.assertEqual(list(m["contracts"]), sorted(m["contracts"]))

    def test_copy_must_keep_the_contract_file_name(self):
        m = copy.deepcopy(MANIFEST)
        m["contracts"]["catalog.tour.v1.json"]["copies"][0]["path"] = "tests/contracts/catalog_tour.json"
        self.assertTrue(any("must keep the contract's file name" in e for e in self.errors(m)))

    def test_copy_repo_must_be_a_consumer_repo(self):
        m = copy.deepcopy(MANIFEST)
        m["contracts"]["catalog.tour.v1.json"]["copies"][0]["repo"] = "Elsewhere"
        self.assertTrue(any("not in consumer_repos" in e for e in self.errors(m)))

    def test_bad_hash_and_bad_name(self):
        m = copy.deepcopy(MANIFEST)
        m["contracts"]["catalog.tour.v1.json"]["sha256"] = "ABC"
        m["contracts"]["Catalog Tour.json"] = {"sha256": sha(B), "copies": []}
        errs = self.errors(m)
        self.assertTrue(any("64 lower-case hex" in e for e in errs))
        self.assertTrue(any("not a contract file name" in e for e in errs))

    def test_malformed_manifest_stops_before_any_read(self):
        m = copy.deepcopy(MANIFEST)
        m["version"] = 2
        gh = FakeGitHub(good_files())
        code, _ = run(m, gh)
        self.assertEqual(code, 1)
        self.assertEqual(gh.reads, [])


class CanonicalTest(unittest.TestCase):
    def test_pins_match_and_unpinned_canonical_file_fails(self):
        with tempfile.TemporaryDirectory() as d:
            c = Path(d)
            (c / "inquiry.submitted.v1.json").write_bytes(A)
            (c / "catalog.tour.v1.json").write_bytes(B)
            code, log = run(MANIFEST, FakeGitHub(good_files()), canonical_dir=c)
            self.assertEqual(code, 0, log)
            (c / "catalog.graph.v1.json").write_bytes(b"{}")
            code, log = run(MANIFEST, FakeGitHub(good_files()), canonical_dir=c)
            self.assertEqual(code, 1)
            self.assertIn("canonical catalog.graph.v1.json: not pinned", log)

    def test_canonical_edited_in_place_fails(self):
        with tempfile.TemporaryDirectory() as d:
            c = Path(d)
            (c / "inquiry.submitted.v1.json").write_bytes(A + b"\n")
            (c / "catalog.tour.v1.json").write_bytes(B)
            code, log = run(MANIFEST, FakeGitHub(good_files()), canonical_dir=c)
            self.assertEqual(code, 1)
            self.assertIn("never edited in place", log)

    def test_committed_pins_match_the_workspace_canonical_files(self):
        """Only in the AA-Ecosys workspace (the root repo is private, CI cannot read it)."""
        for parent in HERE.parents:
            canonical = parent / "docs" / "contracts"
            if (canonical / "README.md").is_file() and (parent / "infra").is_dir():
                break
        else:
            self.skipTest("AA-Ecosys workspace not found above this checkout")
        r = g.Report()
        g.check_canonical(g.load_manifest(), canonical, r)
        self.assertEqual(r.errors, [])


class CliTest(unittest.TestCase):
    """main() end to end with local checkouts (--local) and CONTRACT_COPY_REFS."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = Path(self.tmp.name)
        self.manifest = t / "manifest.json"
        self.manifest.write_text(__import__("json").dumps(MANIFEST))
        self.consumer, self.producer = t / "consumer", t / "producer"
        (self.consumer / "app" / "contracts").mkdir(parents=True)
        (self.consumer / "app" / "contracts" / "inquiry.submitted.v1.json").write_bytes(A)
        (self.consumer / "node_modules" / "x").mkdir(parents=True)
        (self.consumer / "node_modules" / "x" / "catalog.tour.v1.json").write_bytes(b"ignored")
        (self.producer / "tests" / "contracts").mkdir(parents=True)
        (self.producer / "tests" / "contracts" / "catalog.tour.v1.json").write_bytes(B)

    def tearDown(self):
        self.tmp.cleanup()

    def main(self, *extra, env=None):
        def no_network(*_):
            raise AssertionError("GitHub must not be called")
        argv = ["--manifest", str(self.manifest), "--local", f"Consumer={self.consumer}",
                "--local", f"Producer={self.producer}", *extra]
        out = io.StringIO()
        with mock.patch.dict(os.environ, env or {}, clear=False), mock.patch("sys.stdout", out):
            code = g.main(argv, fetch=no_network, list_files=no_network)
        return code, out.getvalue()

    def test_local_green_then_red_after_editing_the_consumer_copy(self):
        code, log = self.main()
        self.assertEqual(code, 0, log)
        f = self.consumer / "app" / "contracts" / "inquiry.submitted.v1.json"
        f.write_bytes(f.read_bytes().replace(b"object", b"array"))
        code, log = self.main()
        self.assertEqual(code, 1)
        self.assertIn("Consumer@worktree:app/contracts/inquiry.submitted.v1.json: modified copy", log)

    def test_contract_copy_refs_env_reaches_the_github_reader(self):
        gh = FakeGitHub({("Consumer", "evidence"): {"app/contracts/inquiry.submitted.v1.json": b"changed"},
                         ("Producer", "main"): {"tests/contracts/catalog.tour.v1.json": B}})
        out = io.StringIO()
        with mock.patch.dict(os.environ, {"CONTRACT_COPY_REFS": "Consumer=evidence"}), \
                mock.patch("sys.stdout", out):
            code = g.main(["--manifest", str(self.manifest)], fetch=gh.fetch, list_files=gh.list_files)
        self.assertEqual(code, 1)
        self.assertIn("Consumer@evidence:app/contracts/inquiry.submitted.v1.json: modified copy", out.getvalue())

    def test_bad_ref_pair_is_refused(self):
        with self.assertRaises(SystemExit):
            g.parse_pairs(["AA-Booking"], "--ref")


if __name__ == "__main__":
    unittest.main()
