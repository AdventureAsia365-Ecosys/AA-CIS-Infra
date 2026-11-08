"""Tests of .github/scripts/lychee_bin.py and the Docs lint link step that uses it (CI hotfix, S273).

Offline, stdlib unittest + PyYAML: the pin file parser and platform choice, the download retries against a fake network
(wrong bytes are thrown away, the pin is never relaxed), the binary extraction from synthetic archives, the run that
replaces lychee-action's entrypoint (command line, report, step summary, exit codes) against a fake lychee, the CLI,
then this repo's committed pin file, composite action and Docs lint workflow. Invented names only. The same file in
every repo that carries .github/actions/lychee.
Run: python3 -B -m unittest discover -s .github/scripts -p 'test_lychee_bin.py'
"""
from __future__ import annotations

import importlib.util
import io
import os
import re
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
SCRIPT = HERE / "lychee_bin.py"
ACTION_DIR = REPO_ROOT / ".github" / "actions" / "lychee"
DOCS_LINT = REPO_ROOT / ".github" / "workflows" / "docs-lint.yml"
WORKFLOWS = REPO_ROOT / ".github" / "workflows"

_spec = importlib.util.spec_from_file_location("lychee_bin", SCRIPT)
lb = importlib.util.module_from_spec(_spec)
sys.modules["lychee_bin"] = lb
_spec.loader.exec_module(lb)

SHA_A = "a" * 64
SHA_B = "b" * 64


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
    import hashlib
    return hashlib.sha256(data).hexdigest()


class Pins(unittest.TestCase):
    def test_parse_select_and_key(self):
        text = (f"# comment\n\nv1.2.3 x86_64-unknown-linux-gnu {SHA_A}\n"
                f"v1.2.3 aarch64-unknown-linux-gnu {SHA_B}  # trailing comment\n")
        pins = lb.parse_pins(text)
        self.assertEqual([p.target for p in pins], ["x86_64-unknown-linux-gnu", "aarch64-unknown-linux-gnu"])
        for machine, sha in (("x86_64", SHA_A), ("AMD64", SHA_A), ("aarch64", SHA_B), ("arm64", SHA_B)):
            self.assertEqual(lb.select(pins, machine).sha256, sha, machine)
        pin = lb.select(pins, "x86_64")
        self.assertEqual(pin.url, "https://github.com/lycheeverse/lychee/releases/download/lychee-v1.2.3/"
                                  "lychee-x86_64-unknown-linux-gnu.tar.gz")
        self.assertEqual(pin.cache_key, f"v1.2.3-x86_64-unknown-linux-gnu-{SHA_A}")

    def test_bad_pin_files_are_refused(self):
        bad = {
            "empty": "# nothing\n",
            "short sha": "v1.2.3 x86_64-unknown-linux-gnu abc\n",
            "upper sha": f"v1.2.3 x86_64-unknown-linux-gnu {SHA_A.upper()}\n",
            "no v": f"1.2.3 x86_64-unknown-linux-gnu {SHA_A}\n",
            "two versions": f"v1.2.3 x86_64-unknown-linux-gnu {SHA_A}\nv1.2.4 aarch64-unknown-linux-gnu {SHA_B}\n",
            "target twice": f"v1.2.3 x86_64-unknown-linux-gnu {SHA_A}\nv1.2.3 x86_64-unknown-linux-gnu {SHA_B}\n",
        }
        for label, text in bad.items():
            with self.subTest(label), self.assertRaises(lb.PinError):
                lb.parse_pins(text)

    def test_unknown_or_unpinned_platform(self):
        pins = lb.parse_pins(f"v1.2.3 x86_64-unknown-linux-gnu {SHA_A}\n")
        with self.assertRaises(lb.PinError):
            lb.select(pins, "riscv64")
        with self.assertRaises(lb.PinError):
            lb.select(pins, "aarch64")


class Download(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.good = b"demo lychee archive bytes"
        self.pin = lb.Pin("v1.2.3", "x86_64-unknown-linux-gnu", _sha(self.good))

    def _fake(self, responses):
        calls = []

        def download(url, dest, timeout):
            calls.append(url)
            item = responses.pop(0)
            if isinstance(item, Exception):
                raise item
            dest.write_bytes(item)
        return download, calls

    def test_retries_until_the_sha_matches(self):
        download, calls = self._fake([OSError("refused"), b"tampered bytes", self.good])
        sleeps, logs = [], []
        dest = self.tmp / "x.tar.gz"
        lb.download_verified(self.pin, dest, download=download, sleep=sleeps.append, log=logs.append, base_delay=5)
        self.assertEqual(dest.read_bytes(), self.good)
        self.assertEqual(len(calls), 3)
        self.assertEqual(len(sleeps), 2)
        self.assertTrue(5 <= sleeps[0] < 6 and 10 <= sleeps[1] < 11, sleeps)
        self.assertIn("does not match the pin", logs[1])

    def test_gives_up_and_leaves_no_file(self):
        download, calls = self._fake([b"tampered"] * 3)
        dest = self.tmp / "x.tar.gz"
        with self.assertRaises(lb.FetchError) as ctx:
            lb.download_verified(self.pin, dest, attempts=3, download=download, sleep=lambda s: None, log=lambda m: None)
        self.assertIn("after 3 attempts", str(ctx.exception))
        self.assertFalse(dest.exists())
        self.assertEqual(len(calls), 3)

    def test_backoff_is_capped(self):
        download, _ = self._fake([OSError("x")] * 8)
        sleeps = []
        with self.assertRaises(lb.FetchError):
            lb.download_verified(self.pin, self.tmp / "x", attempts=8, base_delay=5, download=download,
                                 sleep=sleeps.append, log=lambda m: None)
        self.assertTrue(all(s < 61 for s in sleeps), sleeps)


class FetchAndExtract(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.src = self.tmp / "src.tar.gz"

    def _pin_for(self, data: bytes) -> lb.Pin:
        return lb.Pin("v1.2.3", "x86_64-unknown-linux-gnu", _sha(data))

    def test_cache_hit_does_not_download(self):
        data = _tarball(self.src, {"lychee": b"#!demo binary\n", "README.md": b"demo"})
        pin = self._pin_for(data)
        dest = self.tmp / "cache"
        dest.mkdir()
        (dest / pin.filename).write_bytes(data)

        def no_download(*a):
            raise AssertionError("downloaded on a cache hit")
        logs = []
        binary = lb.fetch(pin, dest, self.tmp / "bin", download=no_download, log=logs.append)
        self.assertEqual(binary.read_bytes(), b"#!demo binary\n")
        self.assertEqual(os.stat(binary).st_mode & 0o777, 0o755)
        self.assertIn("cache hit", logs[0])
        self.assertEqual(sorted(p.name for p in (self.tmp / "bin").iterdir()), ["lychee"])

    def test_a_stale_cached_copy_is_replaced(self):
        data = _tarball(self.src, {"lychee-demo/lychee": b"nested binary"})
        pin = self._pin_for(data)
        dest = self.tmp / "cache"
        dest.mkdir()
        (dest / pin.filename).write_bytes(b"corrupted cache entry")
        binary = lb.fetch(pin, dest, self.tmp / "bin", download=lambda u, d, t: d.write_bytes(data),
                          sleep=lambda s: None, log=lambda m: None)
        self.assertEqual(binary.read_bytes(), b"nested binary")
        self.assertEqual((dest / pin.filename).read_bytes(), data)

    def test_archive_without_a_binary_or_with_only_a_symlink(self):
        for label, members, link in (("none", {"README.md": b"x"}, None), ("deep", {"a/b/lychee": b"x"}, None),
                                     ("symlink", {"README.md": b"x"}, "lychee")):
            with self.subTest(label):
                data = _tarball(self.tmp / f"{label}.tar.gz", members, symlink=link)
                pin = self._pin_for(data)
                dest = self.tmp / f"cache-{label}"
                dest.mkdir()
                (dest / pin.filename).write_bytes(data)
                with self.assertRaises(lb.FetchError):
                    lb.fetch(pin, dest, self.tmp / f"bin-{label}", log=lambda m: None)


class Run(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.env = {"GITHUB_STEP_SUMMARY": str(self.tmp / "summary.md"), "GITHUB_OUTPUT": str(self.tmp / "out.txt"),
                    "GITHUB_REPOSITORY": "demo-org/demo-repo", "GITHUB_RUN_ID": "42"}

    def _runner(self, report: str | None, code: int):
        seen = []

        def runner(cmd, env):
            seen.append(cmd)
            if report is not None:
                Path(cmd[cmd.index("--output") + 1]).write_text(report)
            return subprocess.CompletedProcess(cmd, code)
        return runner, seen

    def test_command_line_matches_lychee_action(self):
        cmd = lb.lychee_command("lychee", "--config tools/docs/lychee.toml --exclude-path docs/demo 'docs/**/*.md'",
                                "/tmp/report")
        self.assertEqual(cmd, ["lychee", "--mode", "task", "--format", "markdown", "--output", "/tmp/report",
                               "--config", "tools/docs/lychee.toml", "--exclude-path", "docs/demo", "docs/**/*.md"])
        self.assertEqual(lb.lychee_command("lychee", "--format json './**/*.md'", "r")[1:5],
                         ["--mode", "task", "--output", "r"])
        with self.assertRaises(ValueError):
            lb.lychee_command("lychee", "--output other.md x.md", "r")
        with self.assertRaises(ValueError):
            lb.lychee_command("lychee", "'unbalanced", "r")

    def test_report_summary_output_and_exit_code(self):
        report = "| Status | Count |\n| Total | 12 |\n| Errors | 1 |\n"
        runner, seen = self._runner(report, 2)
        out = self.tmp / "lychee" / "out.md"
        code = lb.run("'./**/*.md'", lychee="/opt/demo/lychee", output=out, job_summary=True, env=self.env,
                      runner=runner, log=lambda m: None)
        self.assertEqual(code, 2)
        self.assertEqual(seen[0][0], "/opt/demo/lychee")
        self.assertEqual(seen[0][-1], "./**/*.md")
        self.assertTrue(out.read_text().startswith(report))
        self.assertIn("[Full Github Actions output](https://github.com/demo-org/demo-repo/actions/runs/42",
                      out.read_text())
        self.assertEqual(Path(self.env["GITHUB_STEP_SUMMARY"]).read_text(), report)
        self.assertEqual(Path(self.env["GITHUB_OUTPUT"]).read_text(), "exit_code=2\n")

    def test_no_fail_and_no_summary(self):
        runner, _ = self._runner("| Total | 3 |\n", 2)
        code = lb.run("x.md", output=self.tmp / "o.md", fail=False, job_summary=False, env=self.env, runner=runner,
                      log=lambda m: None)
        self.assertEqual(code, 0)
        self.assertFalse(Path(self.env["GITHUB_STEP_SUMMARY"]).exists())
        self.assertEqual(Path(self.env["GITHUB_OUTPUT"]).read_text(), "exit_code=2\n")

    def test_zero_links_fails_unless_allowed(self):
        runner, _ = self._runner("| Total | 0 |\n", 0)
        self.assertEqual(lb.run("x.md", output=self.tmp / "a.md", env=self.env, runner=runner, log=lambda m: None), 1)
        self.assertIn("No links were found", (self.tmp / "a.md").read_text())
        runner, _ = self._runner("| Total | 0 |\n", 0)
        self.assertEqual(lb.run("x.md", output=self.tmp / "b.md", fail_if_empty=False, env=self.env, runner=runner,
                                log=lambda m: None), 0)

    def test_no_report_keeps_the_exit_code(self):
        runner, _ = self._runner(None, 101)
        code = lb.run("x.md", output=self.tmp / "c.md", env={}, runner=runner, log=lambda m: None)
        self.assertEqual(code, 101)
        self.assertIn("No output", (self.tmp / "c.md").read_text())


class Cli(unittest.TestCase):
    def _cli(self, *args):
        return subprocess.run([sys.executable, "-B", str(SCRIPT), *args], capture_output=True, text=True, timeout=60)

    def test_key_and_bad_pins(self):
        tmp = Path(tempfile.mkdtemp())
        pins = tmp / "pins.txt"
        pins.write_text(f"v1.2.3 x86_64-unknown-linux-gnu {SHA_A}\n")
        proc = self._cli("key", "--pins", str(pins), "--machine", "x86_64")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.splitlines(), ["version=v1.2.3", "target=x86_64-unknown-linux-gnu",
                                                    f"sha256={SHA_A}", f"key=v1.2.3-x86_64-unknown-linux-gnu-{SHA_A}"])
        self.assertEqual(self._cli("key", "--pins", str(pins), "--machine", "riscv64").returncode, 2)
        pins.write_text("garbage\n")
        self.assertEqual(self._cli("fetch", "--pins", str(pins), "--dest", str(tmp / "d"), "--bin",
                                   str(tmp / "b")).returncode, 2)

    def test_fetch_from_a_seeded_cache_and_run_bad_args(self):
        tmp = Path(tempfile.mkdtemp())
        data = _tarball(tmp / "src.tar.gz", {"lychee": b"#!/bin/sh\necho demo\n"})
        pins = tmp / "pins.txt"
        pins.write_text(f"v1.2.3 x86_64-unknown-linux-gnu {_sha(data)}\n")
        (tmp / "cache").mkdir()
        (tmp / "cache" / "lychee-v1.2.3-x86_64-unknown-linux-gnu.tar.gz").write_bytes(data)
        proc = self._cli("fetch", "--pins", str(pins), "--machine", "x86_64", "--dest", str(tmp / "cache"),
                         "--bin", str(tmp / "bin"))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertTrue((tmp / "bin" / "lychee").is_file())
        self.assertEqual(self._cli("run", "--args", "--output x.md y.md").returncode, 2)


class ThisRepo(unittest.TestCase):
    """The committed pin file, composite action and Docs lint workflow."""

    @classmethod
    def setUpClass(cls):
        cls.action = yaml.safe_load((ACTION_DIR / "action.yml").read_text())
        cls.docs_lint = yaml.safe_load(DOCS_LINT.read_text())
        # PyYAML reads the bare key `on` as True
        cls.triggers = cls.docs_lint.get("on", cls.docs_lint.get(True))

    def test_committed_pins(self):
        pins = lb.parse_pins((ACTION_DIR / "pins.txt").read_text())
        self.assertEqual({p.target for p in pins}, {"x86_64-unknown-linux-gnu", "aarch64-unknown-linux-gnu"})
        self.assertEqual(lb.DEFAULT_PINS.resolve(), (ACTION_DIR / "pins.txt").resolve())

    def test_action_caches_by_sha_pin_and_one_key(self):
        steps = self.action["runs"]["steps"]
        cache_steps = [s for s in steps if str(s.get("uses", "")).startswith("actions/cache/")]
        self.assertEqual([s["uses"].split("@")[0] for s in cache_steps], ["actions/cache/restore", "actions/cache/save"])
        for s in cache_steps:
            self.assertRegex(s["uses"], r"@[0-9a-f]{40}$")
            self.assertEqual(s["with"]["path"], "${{ runner.temp }}/lychee-cache")
            self.assertEqual(s["with"]["key"], "lychee-v1-${{ steps.key.outputs.key }}")
        text = (ACTION_DIR / "action.yml").read_text()
        self.assertNotIn("curl", text)
        self.assertIn('--pins "$GITHUB_ACTION_PATH/pins.txt"', text)
        self.assertEqual(set(self.action["inputs"]), {"args", "fail", "failIfEmpty", "jobSummary", "output",
                                                      "install-only"})

    def test_no_workflow_downloads_lychee_through_lychee_action(self):
        for wf in sorted(WORKFLOWS.glob("*.y*ml")):
            with self.subTest(wf.name):
                self.assertNotRegex(wf.read_text(), r"uses:\s*lycheeverse/lychee-action")

    def test_docs_lint_link_step_and_required_job_name(self):
        lint = self.docs_lint["jobs"]["lint"]
        self.assertEqual(lint["name"], "Docs lint")  # a required check / merge-queue check name
        self.assertIn("'push'", lint["if"])
        steps = [s for s in lint["steps"] if s.get("name") == "Internal links (offline)"]
        self.assertEqual(len(steps), 1)
        step = steps[0]
        self.assertEqual(step["uses"], "./.github/actions/lychee")
        self.assertEqual(step["if"], "${{ !cancelled() }}")
        self.assertIn("--config tools/docs/lychee.toml", step["with"]["args"])
        self.assertIs(step["with"]["fail"], True)
        self.assertIs(step["with"]["jobSummary"], True)
        # a local action needs the checkout first
        self.assertTrue(str(lint["steps"][0].get("uses", "")).startswith("actions/checkout@"))

    def test_default_branch_warm_job(self):
        job = self.docs_lint["jobs"]["lychee-cache"]
        for event in ("push", "schedule", "workflow_dispatch"):
            self.assertIn(f"'{event}'", job["if"])
        uses = [s for s in job["steps"] if s.get("uses") == "./.github/actions/lychee"]
        self.assertEqual(len(uses), 1)
        self.assertEqual(uses[0]["with"]["install-only"], "true")
        push = self.triggers["push"]
        self.assertEqual(len(push["branches"]), 1)
        self.assertIn(".github/actions/lychee/**", push["paths"])
        self.assertIn(".github/scripts/lychee_bin.py", push["paths"])
        pr_paths = (self.triggers.get("pull_request") or {}).get("paths")
        if pr_paths is not None:  # a path-filtered Docs lint must run when the action or the script changes
            self.assertIn(".github/actions/lychee/**", pr_paths)
            self.assertIn(".github/scripts/lychee_bin.py", pr_paths)

    def test_workflow_lint_runs_these_tests(self):
        text = (WORKFLOWS / "workflow-lint.yml").read_text()
        self.assertIn("-p 'test_lychee_bin.py'", text)
        self.assertEqual(len(re.findall(r'- "\.github/scripts/test_lychee_bin\.py"', text)), 2)


# S273: GitHub throttled unauthenticated release downloads; a release asset goes through `gh` with the job token.
class GhReleaseDownloadTest(unittest.TestCase):
    URL = "https://github.com/invented-org/invented-tool/releases/download/v1.0.0/tool-x86_64.tar.gz"

    def _fake(self, calls):
        def run(argv, check, timeout, capture_output):
            calls.append(argv)
            out = Path(argv[argv.index("--dir") + 1]) / argv[argv.index("--pattern") + 1]
            out.write_bytes(b"invented archive bytes")
        return run

    def test_release_asset_uses_gh_with_a_token(self):
        calls = []
        with tempfile.TemporaryDirectory() as d, unittest.mock.patch.dict(os.environ, {"GH_TOKEN": "job-token"}), \
                unittest.mock.patch.object(lb.shutil, "which", return_value="/usr/bin/gh"):
            dest = Path(d) / "tool.tar.gz"
            self.assertTrue(lb._gh_release_download(self.URL, dest, 30, run=self._fake(calls)))
            self.assertEqual(dest.read_bytes(), b"invented archive bytes")
        self.assertEqual(calls[0][:6], ["gh", "release", "download", "v1.0.0", "--repo", "invented-org/invented-tool"])

    def test_no_token_or_other_host_skips_gh(self):
        calls = []
        env = {k: v for k, v in os.environ.items() if k not in ("GH_TOKEN", "GITHUB_TOKEN")}
        with tempfile.TemporaryDirectory() as d, unittest.mock.patch.dict(os.environ, env, clear=True), \
                unittest.mock.patch.object(lb.shutil, "which", return_value="/usr/bin/gh"):
            self.assertFalse(lb._gh_release_download(self.URL, Path(d) / "a", 30, run=self._fake(calls)))
        with tempfile.TemporaryDirectory() as d, unittest.mock.patch.dict(os.environ, {"GH_TOKEN": "t"}):
            other = "https://downloads.example.test/tool.tar.gz"
            self.assertFalse(lb._gh_release_download(other, Path(d) / "a", 30, run=self._fake(calls)))
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
