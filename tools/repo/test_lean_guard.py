"""Unit tests for lean_guard.py (AA-1161). Stdlib only; each test builds a throwaway git repo.

Run: python3 -m unittest discover -s tools/repo -p 'test_*.py'
Fixture files are invented bytes built in code (a real small PNG, fake ELF / Mach-O / PE headers, padding).
"""

from __future__ import annotations

import contextlib
import io
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import lean_guard as lg  # noqa: E402

# The tests run git in temporary repos: never inherit git's repo-local variables (a pre-push hook exports GIT_DIR and
# friends; a test repo would then write into the real one, S272).
for _git_var in ("GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_CONFIG", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT",
                 "GIT_OBJECT_DIRECTORY", "GIT_DIR", "GIT_WORK_TREE", "GIT_IMPLICIT_WORK_TREE", "GIT_GRAFT_FILE",
                 "GIT_INDEX_FILE", "GIT_NO_REPLACE_OBJECTS", "GIT_REPLACE_REF_BASE", "GIT_PREFIX", "GIT_SHALLOW_FILE",
                 "GIT_COMMON_DIR"):
    os.environ.pop(_git_var, None)

KB = 1024


def png_bytes(width: int = 64, height: int = 32) -> bytes:
    """A valid, small, grey PNG (what compress_images.py leaves of a screenshot)."""

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    raw = b"".join(b"\x00" + bytes([(x * 7 + y) % 256 for x in range(width)]) for y in range(height))
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")


def padded(prefix: bytes, size: int) -> bytes:
    return prefix + b"\x00" * (size - len(prefix))


def pe_header() -> bytes:
    h = bytearray(256)
    h[0:2] = b"MZ"
    h[60:64] = (128).to_bytes(4, "little")
    h[128:132] = b"PE\x00\x00"
    return bytes(h)


class Repo:
    def __init__(self, root: Path):
        self.root = root
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "lane@example.invalid")
        self.git("config", "user.name", "Lean Guard Test")
        self.git("config", "commit.gpgsign", "false")
        self.put("README.md", b"# Sample repo\n")
        self.commit("base")
        self.git("branch", "base")

    def git(self, *args: str) -> str:
        return subprocess.run(["git", "-C", str(self.root), *args], check=True, capture_output=True,
                              text=True).stdout

    def put(self, rel: str, data: bytes) -> None:
        p = self.root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)

    def commit(self, msg: str) -> None:
        self.git("add", "-A")
        self.git("commit", "-q", "--allow-empty", "-m", msg)


class LeanGuardRepoTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.repo = Repo(Path(self._tmp.name))

    def tearDown(self):
        self._tmp.cleanup()

    def run_guard(self, *extra: str) -> tuple[int, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = lg.main(["--repo", str(self.repo.root), "--base", "base", *extra])
        return rc, out.getvalue() + err.getvalue()

    def test_600_kb_image_is_refused(self):
        self.repo.put("docs/audits/s1/shot.png", padded(png_bytes(), 600 * KB))
        self.repo.commit("add a big screenshot")
        rc, out = self.run_guard()
        self.assertEqual(rc, 1, out)
        self.assertIn("REFUSED  docs/audits/s1/shot.png: image-size", out)
        self.assertIn("tools/docs/compress_images.py", out)

    def test_dist_zip_is_refused(self):
        self.repo.put("dist/x.zip", b"PK\x03\x04" + b"\x00" * 100)
        self.repo.commit("add a build zip")
        rc, out = self.run_guard()
        self.assertEqual(rc, 1, out)
        self.assertIn("REFUSED  dist/x.zip: dist-zip", out)

    def test_nested_dist_zip_is_refused_but_a_dist_named_file_is_not(self):
        self.repo.put("infra/dist/lambdas/a.zip", b"PK\x03\x04")
        self.repo.put("docs/dist.zip", b"PK\x03\x04")
        self.repo.commit("zips")
        rc, out = self.run_guard()
        self.assertEqual(rc, 1, out)
        self.assertIn("infra/dist/lambdas/a.zip: dist-zip", out)
        self.assertNotIn("docs/dist.zip", out)

    def test_compressed_screenshot_is_accepted(self):
        self.repo.put("docs/audits/s1/shot.png", png_bytes())
        self.repo.put("docs/audits/s1/report.md", b"# Report\n\n![Home page](shot.png)\n")
        self.repo.commit("add a compressed screenshot")
        rc, out = self.run_guard()
        self.assertEqual(rc, 0, out)
        self.assertIn("2 added/changed file(s)", out)
        self.assertIn("; ok", out)

    def test_total_image_budget(self):
        for i in range(22):  # 22 x 480 KiB, each under the per-image cap, together over 10 MiB
            self.repo.put(f"docs/audits/s1/shot-{i:02d}.png", padded(png_bytes(), 480 * KB))
        self.repo.commit("many screenshots")
        rc, out = self.run_guard()
        self.assertEqual(rc, 1, out)
        self.assertIn("(this change): image-total", out)
        self.assertNotIn("image-size", out)

    def test_executables_are_refused_whatever_their_name(self):
        self.repo.put("tools/bin/helper", padded(b"\x7fELF\x02\x01\x01", 512))
        self.repo.put("tools/bin/helper-mac", padded(b"\xcf\xfa\xed\xfe", 512))
        self.repo.put("tools/bin/helper.dat", padded(pe_header(), 512))
        self.repo.commit("binaries")
        rc, out = self.run_guard()
        self.assertEqual(rc, 1, out)
        self.assertIn("tools/bin/helper: executable: ELF", out)
        self.assertIn("tools/bin/helper-mac: executable: Mach-O", out)
        self.assertIn("tools/bin/helper.dat: executable: PE", out)

    def test_large_file_refused_unless_allowed_with_a_reason(self):
        self.repo.put("data/fixtures/big.json", b"[" + b"0," * (3 * 1024 * KB) + b"0]")
        self.repo.commit("big fixture")
        rc, out = self.run_guard()
        self.assertEqual(rc, 1, out)
        self.assertIn("data/fixtures/big.json: file-size", out)
        self.repo.put(".lean-allow", b"# reviewed exceptions\ndata/fixtures/big.json  replay fixture the parser test needs\n")
        self.repo.commit("allow it")
        rc, out = self.run_guard()
        self.assertEqual(rc, 0, out)
        self.assertIn("allowed  data/fixtures/big.json (.lean-allow: replay fixture the parser test needs)", out)

    def test_allow_entry_without_reason_is_a_config_error(self):
        self.repo.put(".lean-allow", b"data/fixtures/big.json\n")
        self.repo.commit("bad allow file")
        rc, out = self.run_guard()
        self.assertEqual(rc, 2, out)
        self.assertIn("has no reason", out)

    def test_catch_all_allow_entry_is_refused(self):
        self.repo.put(".lean-allow", b"** everything is fine\n")
        self.repo.commit("bad allow file")
        rc, out = self.run_guard()
        self.assertEqual(rc, 2, out)

    def test_pure_rename_and_deletion_are_not_checked(self):
        self.repo.put("docs/old/shot.png", padded(png_bytes(), 600 * KB))
        self.repo.commit("legacy screenshot already in history")
        self.repo.git("branch", "-f", "base", "HEAD")
        (self.repo.root / "docs/new").mkdir(parents=True)
        self.repo.git("mv", "docs/old/shot.png", "docs/new/shot.png")
        self.repo.put("README.md", b"# Sample repo\n\nMoved.\n")
        self.repo.commit("rename only")
        rc, out = self.run_guard()
        self.assertEqual(rc, 0, out)
        self.repo.git("rm", "-q", "docs/new/shot.png")
        self.repo.commit("delete it")
        rc, out = self.run_guard()
        self.assertEqual(rc, 0, out)

    def test_missing_base(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            rc = lg.main(["--repo", str(self.repo.root), "--base", "origin/no-such-branch"])
        self.assertEqual(rc, 2)
        with contextlib.redirect_stdout(out):
            rc = lg.main(["--repo", str(self.repo.root), "--base", "origin/no-such-branch", "--allow-missing-base"])
        self.assertEqual(rc, 0)
        self.assertIn("skipped here, CI still checks it", out.getvalue())

    def test_github_annotations(self):
        self.repo.put("dist/x.zip", b"PK\x03\x04")
        self.repo.commit("zip")
        rc, out = self.run_guard("--github")
        self.assertEqual(rc, 1)
        self.assertIn("::error file=dist/x.zip,title=Lean guard dist-zip::", out)

    def test_non_ascii_and_space_names(self):
        self.repo.put("docs/audits/ảnh chụp.png", padded(png_bytes(), 600 * KB))
        self.repo.commit("vietnamese name")
        rc, out = self.run_guard()
        self.assertEqual(rc, 1, out)
        self.assertIn("docs/audits/ảnh chụp.png: image-size", out)

    def test_cli_entry_point(self):
        self.repo.put("dist/x.zip", b"PK\x03\x04")
        self.repo.commit("zip")
        proc = subprocess.run([sys.executable, "-I", "-B", str(Path(lg.__file__)), "--base", "base"],
                              cwd=self.repo.root, capture_output=True, text=True, check=False)
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertIn("dist-zip", proc.stdout)


    def test_blobless_clone_with_prefetch(self):
        """The CI path: a blobless (partial) sparse clone, the changed blobs fetched in one round trip."""
        self.repo.put("dist/x.zip", b"PK\x03\x04")
        self.repo.put("docs/audits/s1/shot.png", padded(png_bytes(), 600 * KB))
        self.repo.put("docs/audits/s1/ok.png", png_bytes())
        self.repo.commit("change")
        up = "git -c uploadpack.allowFilter=true -c uploadpack.allowAnySHA1InWant=true upload-pack"
        clone = Path(self._tmp.name + "-clone")
        self.addCleanup(shutil.rmtree, clone, True)
        subprocess.run(["git", "-c", "protocol.file.allow=always", "clone", "-q", "--filter=blob:none", "--no-checkout",
                        f"--upload-pack={up}", f"file://{self.repo.root}", str(clone)], check=True, capture_output=True)
        for key, value in (("remote.origin.uploadpack", up), ("protocol.file.allow", "always")):
            subprocess.run(["git", "-C", str(clone), "config", key, value], check=True)
        subprocess.run(["git", "-C", str(clone), "branch", "-q", "base", "origin/base"], check=True)
        self.assertEqual(lg.git(str(clone), "config", "--get", "remote.origin.promisor").decode().strip(), "true")
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            rc = lg.main(["--repo", str(clone), "--base", "base", "--head", "origin/main", "--prefetch"])
        self.assertEqual(rc, 1, out.getvalue())
        self.assertIn("dist/x.zip: dist-zip", out.getvalue())
        self.assertIn("docs/audits/s1/shot.png: image-size", out.getvalue())
        self.assertNotIn("ok.png:", out.getvalue())


class PureRuleTests(unittest.TestCase):
    def test_binary_kind(self):
        self.assertEqual(lg.binary_kind(b"\x7fELF\x02"), "ELF")
        self.assertEqual(lg.binary_kind(b"\xfe\xed\xfa\xcf"), "Mach-O")
        self.assertEqual(lg.binary_kind(b"\xca\xfe\xba\xbe\x00\x00\x00\x02"), "Mach-O universal")
        self.assertIsNone(lg.binary_kind(b"\xca\xfe\xba\xbe\x00\x00\x00\x41"))  # Java class file, version 65
        self.assertEqual(lg.binary_kind(pe_header()), "PE")
        self.assertIsNone(lg.binary_kind(b"MZ just text that starts with MZ" + b" " * 64))
        self.assertIsNone(lg.binary_kind(png_bytes()))
        self.assertIsNone(lg.binary_kind(b""))

    def test_svg_is_not_a_raster_image(self):
        self.assertFalse(lg.is_raster("docs/architecture/diagrams/infra.svg"))
        self.assertTrue(lg.is_raster("docs/a/B.JPG"))

    def test_parse_raw_diff(self):
        z = "0" * 40
        a, b, c = "a" * 40, "b" * 40, "c" * 40
        raw = (f":000000 100644 {z} {a} A\0new.png\0"
               f":100644 100644 {a} {a} R100\0old.png\0moved.png\0"
               f":100644 100644 {a} {b} R090\0x.png\0y.png\0"
               f":100644 000000 {b} {z} D\0gone.bin\0"
               f":000000 120000 {z} {c} A\0link\0"
               f":000000 160000 {z} {c} A\0sub\0").encode()
        self.assertEqual(lg.parse_raw_diff(raw), [("new.png", a), ("y.png", b)])

    def test_allow_glob(self):
        entries = lg.parse_allow("tests/fixtures/*.bin  parser fixtures\n./docs/x.pdf the signed contract\n")
        self.assertIsNotNone(lg.allowed_by("tests/fixtures/a/b.bin", entries))
        self.assertIsNotNone(lg.allowed_by("docs/x.pdf", entries))
        self.assertIsNone(lg.allowed_by("tests/other.bin", entries))


if __name__ == "__main__":
    unittest.main()
