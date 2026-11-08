"""Tests of .github/scripts/release_bin.py and .github/actions/release-bin (S273, AA-1024).

Offline, stdlib unittest + PyYAML: the pin file parser and platform choice, the download retries against a fake network
(wrong bytes are thrown away, the pin is never relaxed), the gh -> plain HTTPS fallback with only `path=` on
stdout (stdout is $GITHUB_OUTPUT), the member extraction from synthetic archives, a kept file
(member '-'), the CLI, then this repo's committed pin file and composite action, and that no workflow of this repo
still runs a tool the action replaces through its own download (anchore/sbom-action, setup-trivy). Invented names only.
The same file in every repo that carries .github/actions/release-bin.
Run: python3 -B -m unittest discover -s .github/scripts -p 'test_release_bin.py'
"""
from __future__ import annotations

import ast
import hashlib
import importlib.util
import io
import os
import subprocess
import sys
import tarfile
import tempfile
import unittest
import unittest.mock
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent.parent
SCRIPT = HERE / "release_bin.py"
ACTION_DIR = REPO_ROOT / ".github" / "actions" / "release-bin"
WORKFLOWS = REPO_ROOT / ".github" / "workflows"

_spec = importlib.util.spec_from_file_location("release_bin", SCRIPT)
rb = importlib.util.module_from_spec(_spec)
sys.modules["release_bin"] = rb
_spec.loader.exec_module(rb)

SHA_A = "a" * 64
SHA_B = "b" * 64
URL = "https://github.com/demo-org/demotool/releases/download/v2.3.4/demotool_2.3.4_linux_{}.tar.gz"


def _tarball(path: Path, members: dict[str, bytes], symlink: str | None = None) -> bytes:
    with tarfile.open(path, "w:gz") as tar:
        for name, data in members.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mode = 0o644
            tar.addfile(info, io.BytesIO(data))
        if symlink:
            info = tarfile.TarInfo(symlink)
            info.type = tarfile.SYMTYPE
            info.linkname = "/etc/passwd"
            tar.addfile(info)
    return path.read_bytes()


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _pins_text(sha_x86: str = SHA_A, sha_arm: str = SHA_B, member: str = "demotool") -> str:
    return (f"# comment\n\ndemotool v2.3.4 x86_64 {sha_x86} {URL.format('amd64')} {member}\n"
            f"demotool v2.3.4 aarch64 {sha_arm} {URL.format('arm64')} {member}  # trailing comment\n"
            f"otherpkg 1.0.0.7 x86_64 {SHA_B} https://downloads.example.test/otherpkg/1.0.0.7/otherpkg.deb -\n")


class Pins(unittest.TestCase):
    def test_parse_select_and_key(self):
        pins = rb.parse_pins(_pins_text())
        self.assertEqual([(p.tool, p.arch) for p in pins],
                         [("demotool", "x86_64"), ("demotool", "aarch64"), ("otherpkg", "x86_64")])
        for machine, sha in (("x86_64", SHA_A), ("AMD64", SHA_A), ("X64", SHA_A), ("aarch64", SHA_B), ("arm64", SHA_B)):
            self.assertEqual(rb.select(pins, "demotool", machine).sha256, sha, machine)
        pin = rb.select(pins, "demotool", "x86_64")
        self.assertEqual(pin.cache_key, f"demotool-v2.3.4-x86_64-{SHA_A}")
        self.assertEqual(pin.filename, "demotool-v2.3.4-x86_64-demotool_2.3.4_linux_amd64.tar.gz")
        self.assertEqual(rb.select(pins, "otherpkg", "amd64").member, "-")

    def test_bad_pin_files_are_refused(self):
        good = f"demotool v2.3.4 x86_64 {SHA_A} {URL.format('amd64')} demotool\n"
        bad = {
            "empty": "# nothing\n",
            "short sha": good.replace(SHA_A, "abc"),
            "upper sha": good.replace(SHA_A, SHA_A.upper()),
            "bad arch": good.replace("x86_64", "riscv64"),
            "http url": good.replace("https://", "http://"),
            "no member": good.replace(" demotool\n", "\n"),
            "url without the version": good.replace("v2.3.4/demotool_2.3.4", "latest/demotool"),
            "two versions": good + good.replace("v2.3.4 x86_64", "v2.3.5 aarch64").replace("2.3.4", "2.3.5"),
            "arch twice": good + good,
        }
        for label, text in bad.items():
            with self.assertRaises(rb.PinError, msg=label):
                rb.parse_pins(text)

    def test_unknown_tool_or_unpinned_platform(self):
        pins = rb.parse_pins(_pins_text())
        with self.assertRaises(rb.PinError):
            rb.select(pins, "nosuchtool", "x86_64")
        with self.assertRaises(rb.PinError):
            rb.select(pins, "demotool", "ppc64le")
        with self.assertRaises(rb.PinError):
            rb.select(pins, "otherpkg", "arm64")


class Download(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.good = b"demotool release bytes"
        self.pin = rb.Pin("demotool", "v2.3.4", "x86_64", _sha(self.good), URL.format("amd64"), "demotool")

    def tearDown(self):
        self.tmp.cleanup()

    def _net(self, replies):
        calls = []

        def download(url, dest, timeout):
            calls.append(url)
            reply = replies[min(len(calls), len(replies)) - 1]
            if isinstance(reply, Exception):
                raise reply
            dest.write_bytes(reply)
        return download, calls

    def test_retries_until_the_sha_matches(self):
        download, calls = self._net([OSError("HTTP 504"), b"wrong bytes", self.good])
        sleeps, logs = [], []
        dest = self.dir / "f.tar.gz"
        rb.download_verified(self.pin, dest, attempts=4, base_delay=1, download=download, sleep=sleeps.append,
                             log=logs.append)
        self.assertEqual(dest.read_bytes(), self.good)
        self.assertEqual(len(calls), 3)
        self.assertEqual(len(sleeps), 2)
        self.assertTrue(any("does not match the pin" in m for m in logs))

    def test_gives_up_and_leaves_no_file(self):
        download, _ = self._net([b"wrong bytes"])
        dest = self.dir / "f.tar.gz"
        with self.assertRaises(rb.FetchError):
            rb.download_verified(self.pin, dest, attempts=3, base_delay=0, download=download, sleep=lambda s: None,
                                 log=lambda m: None)
        self.assertFalse(dest.exists())

    def test_backoff_is_capped(self):
        download, _ = self._net([OSError("down")])
        sleeps = []
        with self.assertRaises(rb.FetchError):
            rb.download_verified(self.pin, self.dir / "f", attempts=6, base_delay=40, download=download,
                                 sleep=sleeps.append, log=lambda m: None)
        self.assertTrue(all(s <= 61 for s in sleeps))


class FetchAndExtract(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.src = self.dir / "src.tar.gz"

    def tearDown(self):
        self.tmp.cleanup()

    def test_cache_hit_does_not_download(self):
        data = _tarball(self.src, {"README.md": b"readme", "demotool": b"#!/bin/sh\necho demo\n"})
        pin = rb.Pin("demotool", "v2.3.4", "x86_64", _sha(data), URL.format("amd64"), "demotool")
        dest = self.dir / "cache"
        dest.mkdir()
        (dest / pin.filename).write_bytes(data)

        def no_network(*a, **k):
            raise AssertionError("downloaded on a cache hit")
        binary = rb.fetch(pin, dest, self.dir / "bin", download=no_network, log=lambda m: None)
        self.assertEqual(binary.read_bytes(), b"#!/bin/sh\necho demo\n")
        self.assertTrue(os.access(binary, os.X_OK))
        self.assertEqual(sorted(p.name for p in (self.dir / "bin").iterdir()), ["demotool"])

    def test_a_stale_cached_copy_is_replaced_and_a_nested_member_found(self):
        data = _tarball(self.src, {"demotool_2.3.4/demotool": b"new"})
        pin = rb.Pin("demotool", "v2.3.4", "x86_64", _sha(data), URL.format("amd64"), "demotool")
        dest = self.dir / "cache"
        dest.mkdir()
        (dest / pin.filename).write_bytes(b"stale")
        binary = rb.fetch(pin, dest, self.dir / "bin", download=lambda u, d, t: d.write_bytes(data),
                          sleep=lambda s: None, log=lambda m: None)
        self.assertEqual(binary.read_bytes(), b"new")

    def test_archive_without_the_member_or_with_only_a_symlink(self):
        for members, link in (({"README.md": b"x"}, None), ({}, "demotool"), ({"a/b/demotool": b"deep"}, None)):
            data = _tarball(self.src, members, link)
            pin = rb.Pin("demotool", "v2.3.4", "x86_64", _sha(data), URL.format("amd64"), "demotool")
            with self.assertRaises(rb.FetchError):
                rb.fetch(pin, self.dir / "cache", self.dir / "bin", download=lambda u, d, t: d.write_bytes(data),
                         sleep=lambda s: None, log=lambda m: None)

    def test_member_dash_keeps_the_verified_file(self):
        data = b"!<arch>\ninvented package bytes"
        pin = rb.Pin("otherpkg", "1.0.0.7", "x86_64", _sha(data), "https://downloads.example.test/1.0.0.7/o.deb", "-")
        path = rb.fetch(pin, self.dir / "cache", self.dir / "bin", download=lambda u, d, t: d.write_bytes(data),
                        sleep=lambda s: None, log=lambda m: None)
        self.assertEqual(path.read_bytes(), data)
        self.assertFalse((self.dir / "bin").exists())


class Cli(unittest.TestCase):
    def test_key_fetch_and_bad_input(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            data = _tarball(tmp / "src.tar.gz", {"demotool": b"bin"})
            pins = tmp / "pins.txt"
            pins.write_text(_pins_text(sha_x86=_sha(data)), encoding="utf-8")
            out = io.StringIO()
            with unittest.mock.patch("sys.stdout", out):
                self.assertEqual(rb.main(["key", "--tool", "demotool", "--pins", str(pins), "--machine", "x86_64"]), 0)
            self.assertIn(f"key=demotool-v2.3.4-x86_64-{_sha(data)}", out.getvalue())
            cache = tmp / "cache"
            cache.mkdir()
            (cache / f"demotool-v2.3.4-x86_64-{URL.format('amd64').rsplit('/', 1)[-1]}").write_bytes(data)
            out = io.StringIO()
            with unittest.mock.patch("sys.stdout", out), unittest.mock.patch("sys.stderr", io.StringIO()):
                self.assertEqual(rb.main(["fetch", "--tool", "demotool", "--pins", str(pins), "--machine", "x86_64",
                                          "--dest", str(cache), "--bin", str(tmp / "bin")]), 0)
            self.assertEqual(out.getvalue(), f"path={tmp / 'bin' / 'demotool'}\n")  # only `path=` on stdout
            with unittest.mock.patch("sys.stderr", io.StringIO()):
                self.assertEqual(rb.main(["key", "--tool", "nosuchtool", "--pins", str(pins)]), 2)
                self.assertEqual(rb.main(["key", "--tool", "demotool", "--pins", str(tmp / "missing.txt")]), 2)


class StdoutIsTheOutputFile(unittest.TestCase):
    """The action sends stdout into $GITHUB_OUTPUT: any line there that is not `name=value` fails the step."""

    def test_gh_failure_falls_back_to_https_and_stdout_stays_path_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            data = _tarball(tmp / "src.tar.gz", {"demotool": b"bin"})
            pins = tmp / "pins.txt"
            pins.write_text(_pins_text(sha_x86=_sha(data)), encoding="utf-8")
            fakebin = tmp / "fakebin"
            fakebin.mkdir()
            gh = fakebin / "gh"
            gh.write_text("#!/bin/sh\necho 'HTTP 403: rate limited' >&2\nexit 1\n", encoding="utf-8")
            gh.chmod(0o755)
            urls = []

            def fake_urlopen(req, timeout=None):
                urls.append(req.full_url)
                return io.BytesIO(data)
            out, err = io.StringIO(), io.StringIO()
            env = {"GH_TOKEN": "x", "PATH": f"{fakebin}{os.pathsep}{os.environ.get('PATH', '')}"}
            with unittest.mock.patch.dict(os.environ, env), \
                    unittest.mock.patch.object(rb.urllib.request, "urlopen", fake_urlopen), \
                    unittest.mock.patch("sys.stdout", out), unittest.mock.patch("sys.stderr", err):
                code = rb.main(["fetch", "--tool", "demotool", "--pins", str(pins), "--machine", "x86_64",
                                "--dest", str(tmp / "cache"), "--bin", str(tmp / "bin")])
            self.assertEqual(code, 0, err.getvalue())
            self.assertEqual(urls, [URL.format("amd64")])
            self.assertEqual(out.getvalue(), f"path={tmp / 'bin' / 'demotool'}\n")
            self.assertIn("::warning::authenticated gh download failed (CalledProcessError)", err.getvalue())
            self.assertEqual((tmp / "bin" / "demotool").read_bytes(), b"bin")

    def test_every_stdout_print_is_a_name_value_line(self):
        tree = ast.parse(SCRIPT.read_text(encoding="utf-8"))
        for node in ast.walk(tree):
            if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "print"):
                continue
            to_stderr = any(k.arg == "file" and ast.unparse(k.value) == "sys.stderr" for k in node.keywords)
            if to_stderr:
                continue
            first = node.args[0] if node.args else None
            lead = ""
            if isinstance(first, ast.JoinedStr) and first.values and isinstance(first.values[0], ast.Constant):
                lead = str(first.values[0].value)
            self.assertRegex(lead, r"^[a-z0-9_]+=", f"line {node.lineno}: a stdout print that is not name=value")


class GhReleaseDownload(unittest.TestCase):
    def test_release_asset_uses_gh_with_a_token(self):
        calls = []

        def fake_run(cmd, **kw):
            calls.append(cmd)
            Path(cmd[cmd.index("--dir") + 1], cmd[cmd.index("--pattern") + 1]).write_bytes(b"asset")
            return subprocess.CompletedProcess(cmd, 0)
        with tempfile.TemporaryDirectory() as tmp, \
                unittest.mock.patch.dict(os.environ, {"GH_TOKEN": "x"}), \
                unittest.mock.patch.object(rb.shutil, "which", return_value="/usr/bin/gh"):
            dest = Path(tmp) / "f.tar.gz"
            self.assertTrue(rb._gh_release_download(URL.format("amd64"), dest, 30, run=fake_run))
            self.assertEqual(dest.read_bytes(), b"asset")
        self.assertEqual(calls[0][:5], ["gh", "release", "download", "v2.3.4", "--repo"])

    def test_no_token_or_other_host_skips_gh(self):
        env = {k: v for k, v in os.environ.items() if k not in ("GH_TOKEN", "GITHUB_TOKEN")}
        with tempfile.TemporaryDirectory() as tmp, unittest.mock.patch.dict(os.environ, env, clear=True):
            self.assertFalse(rb._gh_release_download(URL.format("amd64"), Path(tmp) / "f", 30))
        with tempfile.TemporaryDirectory() as tmp, unittest.mock.patch.dict(os.environ, {"GH_TOKEN": "x"}):
            self.assertFalse(rb._gh_release_download("https://downloads.example.test/a/1.0/o.deb", Path(tmp) / "f", 30))


class ThisRepo(unittest.TestCase):
    def setUp(self):
        with open(ACTION_DIR / "action.yml", encoding="utf-8") as fh:
            self.action = yaml.safe_load(fh)

    def test_committed_pins_cover_both_runner_platforms(self):
        pins = rb.parse_pins((ACTION_DIR / "pins.txt").read_text(encoding="utf-8"))
        tools = {p.tool for p in pins}
        self.assertTrue({"syft", "trivy", "actionlint", "oasdiff"} <= tools)
        for tool in tools:
            self.assertEqual({p.arch for p in pins if p.tool == tool}, {"x86_64", "aarch64"}, tool)

    def test_action_restores_fetches_and_saves_one_key(self):
        steps = self.action["runs"]["steps"]
        by_id = {s.get("id"): s for s in steps}
        restore, save = by_id["restore"], steps[-1]
        self.assertTrue(restore["uses"].startswith("actions/cache/restore@"))
        self.assertTrue(save["uses"].startswith("actions/cache/save@"))
        self.assertRegex(restore["uses"], r"@[0-9a-f]{40}$")
        self.assertEqual(restore["with"], save["with"])
        self.assertIn("steps.key.outputs.key", restore["with"]["key"])
        self.assertEqual(save["if"], "steps.restore.outputs.cache-hit != 'true'")
        self.assertIn("GH_TOKEN", by_id["fetch"]["env"])
        self.assertIn("release_bin.py\" fetch", by_id["fetch"]["run"])

    def test_no_workflow_fetches_syft_or_trivy_through_its_own_action(self):
        for path in sorted(WORKFLOWS.glob("*.y*ml")):
            wf = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
            for job in (wf.get("jobs") or {}).values():
                for step in (job or {}).get("steps") or []:
                    uses = str(step.get("uses") or "")
                    self.assertFalse(uses.startswith(("anchore/sbom-action@", "aquasecurity/setup-trivy@")),
                                     f"{path.name}: {uses}")
                    if uses.startswith("aquasecurity/trivy-action@"):
                        self.assertEqual(str((step.get("with") or {}).get("skip-setup-trivy")), "true", path.name)


if __name__ == "__main__":
    unittest.main()
