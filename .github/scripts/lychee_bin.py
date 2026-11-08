#!/usr/bin/env python3
"""The lychee link checker from a cached, hash-checked copy, then the same run lychee-action did (CI hotfix, S273).

The Docs lint job ran lycheeverse/lychee-action v2.9.0, which downloads the lychee v0.24.2 release tarball from
github.com on every run with a bare `curl -sfLO` (no retry). On 08/11/2026 that download failed several times (curl
exit 22 after 2 minutes) and the "Docs lint" check went red only for that, which also ejected pull requests from the
merge queues. lychee-action has no input that skips its download. This script keeps what runs the same (lychee v0.24.2,
the same arguments and config, the same report) and changes only where the binary comes from:

  key    prints `version=`, `target=`, `sha256=` and `key=` lines for `$GITHUB_OUTPUT`, from the pin file
         (.github/actions/lychee/pins.txt) and this machine's platform: the cache key moves only when the pin moves.
  fetch  puts the pinned release tarball in --dest, checked against the pinned sha256: a verified copy already there (a
         cache hit) is kept; else it is downloaded over HTTP/1.1 (urllib), with retries and backoff, and checked. Bytes
         that never match the pin fail the step: the pin is never relaxed. Then the `lychee` binary (only that member)
         is extracted into --bin.
  run    what lychee-action's entrypoint.sh did: `lychee --mode task --format markdown --output <tmp> <args>`, the
         report copied to --output and printed, written to the step summary (--job-summary), `exit_code=` written to
         `$GITHUB_OUTPUT`, a report with 0 links found fails (--fail-if-empty), and lychee's exit code is passed on
         (--fail). `<args>` is split like a shell would (quotes kept: a quoted glob reaches lychee as is).

Used by .github/actions/lychee (actions/cache, keyed on version + platform + sha256). Stdlib only. The same file in the
root repo, AA-Booking, AA-Partner, AA-TripPlanner-Web and AA-CIS-Infra: change it in all of them in the same wave.
Run: python3 .github/scripts/lychee_bin.py key [--pins FILE] [--machine ARCH]
     python3 .github/scripts/lychee_bin.py fetch --dest DIR --bin DIR [--pins FILE] [--attempts N] [--base-delay S]
     python3 .github/scripts/lychee_bin.py run --args "ARGS" [--lychee PATH] [--output FILE] [--no-fail]
       [--no-fail-if-empty] [--job-summary]
Exit 0 = done (run: lychee's code unless --no-fail), 1 = the binary could not be fetched or verified, 2 = a bad pin
file or platform.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import platform
import random
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_PINS = HERE.parent / "actions" / "lychee" / "pins.txt"
PIN_LINE = re.compile(r"^(?P<version>v\d+\.\d+\.\d+)\s+(?P<target>[a-z0-9_]+-[a-z0-9_]+-[a-z0-9_]+-[a-z0-9_]+)"
                      r"\s+(?P<sha>[0-9a-f]{64})\s*$")
URL = "https://github.com/lycheeverse/lychee/releases/download/lychee-{version}/lychee-{target}.tar.gz"
MACHINES = {"x86_64": "x86_64", "amd64": "x86_64", "aarch64": "aarch64", "arm64": "aarch64"}
EMPTY_REPORT = re.compile(r"Total\s+\|\s+0")
CHUNK = 1 << 16
USER_AGENT = "aa-ci-lychee-bin/1"


class PinError(ValueError):
    """The pin file is malformed, or has no pin for this platform."""


class FetchError(RuntimeError):
    """The tarball could not be fetched with the pinned sha256, or holds no lychee binary."""


@dataclass(frozen=True)
class Pin:
    version: str
    target: str
    sha256: str

    @property
    def url(self) -> str:
        return URL.format(version=self.version, target=self.target)

    @property
    def filename(self) -> str:
        return f"lychee-{self.version}-{self.target}.tar.gz"

    @property
    def cache_key(self) -> str:
        return f"{self.version}-{self.target}-{self.sha256}"


def parse_pins(text: str) -> list[Pin]:
    """`<version> <target> <sha256>` lines (comments and blank lines skipped); one version, one line per target."""
    pins: list[Pin] = []
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        m = PIN_LINE.match(line)
        if not m:
            raise PinError(f"line {lineno}: expected '<vX.Y.Z> <target triple> <64 hex sha256>', got {line!r}")
        pins.append(Pin(m.group("version"), m.group("target"), m.group("sha")))
    if not pins:
        raise PinError("no pin")
    if len({p.version for p in pins}) != 1:
        raise PinError(f"more than one version pinned: {sorted({p.version for p in pins})}")
    targets = [p.target for p in pins]
    if len(set(targets)) != len(targets):
        raise PinError("a target is pinned twice")
    return pins


def target_for(machine: str) -> str:
    arch = MACHINES.get(machine.lower())
    if arch is None:
        raise PinError(f"no lychee build pinned for machine {machine!r}")
    return f"{arch}-unknown-linux-gnu"


def select(pins: list[Pin], machine: str) -> Pin:
    target = target_for(machine)
    for pin in pins:
        if pin.target == target:
            return pin
    raise PinError(f"no pin for {target} (pinned: {', '.join(p.target for p in pins)})")


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(CHUNK), b""):
            h.update(block)
    return h.hexdigest()


def verified(path: Path, sha: str) -> bool:
    return path.is_file() and sha256_of(path) == sha


_GH_RELEASE = re.compile(r"^https://github\.com/([^/]+)/([^/]+)/releases/download/([^/]+)/([^/?#]+)$")


def _gh_release_download(url: str, dest: Path, timeout: float, run=subprocess.run) -> bool:
    """Authenticated download of a public GitHub release asset through `gh` (S273: GitHub throttled
    unauthenticated release downloads). True when gh fetched the file; False when this path does not apply."""
    m = _GH_RELEASE.match(url)
    if not m or not shutil.which("gh") or not (os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")):
        return False
    owner, repo, tag, name = m.groups()
    work = Path(tempfile.mkdtemp(dir=dest.parent, prefix=".gh-"))
    try:
        run(["gh", "release", "download", tag, "--repo", f"{owner}/{repo}", "--pattern", name, "--dir", str(work)],
            check=True, timeout=timeout, capture_output=True)
        os.replace(work / name, dest)
        return True
    finally:
        shutil.rmtree(work, ignore_errors=True)


def _download(url: str, dest: Path, timeout: float) -> None:
    try:
        if _gh_release_download(url, dest, timeout):
            return
    except Exception as exc:  # noqa: BLE001 - fall back to the plain HTTPS download below
        print(f"::warning::authenticated gh download failed ({type(exc).__name__}); trying plain HTTPS")
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    fd, tmp = tempfile.mkstemp(dir=dest.parent, prefix=".part-")
    try:
        with os.fdopen(fd, "wb") as out, urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310 (pinned)
            shutil.copyfileobj(resp, out, CHUNK)
        os.replace(tmp, dest)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def download_verified(pin: Pin, dest: Path, *, attempts: int = 6, base_delay: float = 5.0, timeout: float = 60.0,
                      download=_download, sleep=time.sleep, log=print) -> None:
    """Download `pin` to `dest` until its sha256 matches; backoff base_delay * 2**n (max 60 s) plus jitter."""
    last = ""
    for n in range(1, attempts + 1):
        try:
            download(pin.url, dest, timeout)
            got = sha256_of(dest)
            if got == pin.sha256:
                return
            dest.unlink(missing_ok=True)
            last = f"sha256 {got} does not match the pin {pin.sha256}"
        except Exception as exc:  # network errors of any kind: retry
            last = f"{type(exc).__name__}: {exc}"[:300]
        if n < attempts:
            delay = min(60.0, base_delay * 2 ** (n - 1)) + random.uniform(0, 1)
            log(f"::warning::{pin.filename}: attempt {n}/{attempts} failed ({last}); retrying in {delay:.0f} s")
            sleep(delay)
    raise FetchError(f"{pin.filename}: no verified copy after {attempts} attempts (last: {last})")


def extract_binary(tarball: Path, bin_dir: Path) -> Path:
    """Copy the archive's `lychee` file (top level or one folder down) to bin_dir/lychee, mode 0755; nothing else."""
    bin_dir.mkdir(parents=True, exist_ok=True)
    with tarfile.open(tarball, "r:gz") as tar:
        members = [m for m in tar.getmembers() if m.isfile() and m.name.lstrip("./").count("/") <= 1
                   and os.path.basename(m.name) == "lychee"]
        if not members:
            raise FetchError(f"{tarball.name}: no lychee binary in the archive (did its layout change?)")
        src = tar.extractfile(members[0])
        if src is None:
            raise FetchError(f"{tarball.name}: cannot read {members[0].name}")
        fd, tmp = tempfile.mkstemp(dir=bin_dir, prefix=".lychee-")
        with os.fdopen(fd, "wb") as out, src:
            shutil.copyfileobj(src, out, CHUNK)
    os.chmod(tmp, 0o755)
    target = bin_dir / "lychee"
    os.replace(tmp, target)
    return target


def fetch(pin: Pin, dest: Path, bin_dir: Path, *, log=print, **download_kw) -> Path:
    """The pinned tarball as a verified file in `dest`, its binary in `bin_dir`; returns the binary path."""
    dest.mkdir(parents=True, exist_ok=True)
    tarball = dest / pin.filename
    if verified(tarball, pin.sha256):
        log(f"{pin.filename}: verified local copy (cache hit)")
    else:
        tarball.unlink(missing_ok=True)
        log(f"{pin.filename}: downloading {pin.url}")
        download_verified(pin, tarball, log=log, **download_kw)
        log(f"{pin.filename}: downloaded, sha256 verified")
    binary = extract_binary(tarball, bin_dir)
    log(f"lychee {pin.version} ({pin.target}) installed at {binary}")
    return binary


def lychee_command(lychee: str, args: str, report: str) -> list[str]:
    """lychee-action's command line: `lychee --mode task --format markdown --output <report> <args>`."""
    extra = shlex.split(args)
    cmd = [lychee]
    if not any(a == "--mode" or a.startswith("--mode=") for a in extra):
        cmd += ["--mode", "task"]
    if not any(a == "--format" or a.startswith("--format=") for a in extra):
        cmd += ["--format", "markdown"]
    if any(a in ("--output", "-o") or a.startswith("--output=") for a in extra):
        raise ValueError("--output is set by the action (its `output` input); remove it from args")
    return cmd + ["--output", report] + extra


def run(args: str, *, lychee: str = "lychee", output: Path = Path("lychee/out.md"), fail: bool = True,
        fail_if_empty: bool = True, job_summary: bool = False, env: dict | None = None,
        runner=subprocess.run, log=print) -> int:
    env = dict(os.environ if env is None else env)
    fd, tmp = tempfile.mkstemp(prefix="lychee-report-")
    os.close(fd)
    report = Path(tmp)
    report.unlink()
    try:
        code = runner(lychee_command(lychee, args, str(report)), env=env).returncode
        text = report.read_text(encoding="utf-8") if report.is_file() else ""
    finally:
        report.unlink(missing_ok=True)
    empty = False
    if not text:
        text = "No output. Check the run log to see if lychee panicked.\n"
    elif fail_if_empty and EMPTY_REPORT.search(text):
        text += ("No links were found. This usually indicates a configuration error.\n"
                 "If this was expected, set 'failIfEmpty: false'.\n")
        empty = True
    output.parent.mkdir(parents=True, exist_ok=True)
    run_url = ""
    if env.get("GITHUB_REPOSITORY") and env.get("GITHUB_RUN_ID"):
        server = env.get("GITHUB_SERVER_URL", "https://github.com")
        run_url = f"{server}/{env['GITHUB_REPOSITORY']}/actions/runs/{env['GITHUB_RUN_ID']}?check_suite_focus=true"
    output.write_text(text + (f"[Full Github Actions output]({run_url})\n" if run_url else ""), encoding="utf-8")
    log(text)
    if job_summary and env.get("GITHUB_STEP_SUMMARY"):
        Path(env["GITHUB_STEP_SUMMARY"]).write_text(text, encoding="utf-8")
    if env.get("GITHUB_OUTPUT"):
        with open(env["GITHUB_OUTPUT"], "a", encoding="utf-8") as fh:
            fh.write(f"exit_code={code}\n")
    if empty:
        return 1
    return code if fail else 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    k = sub.add_parser("key")
    k.add_argument("--pins", type=Path, default=DEFAULT_PINS)
    k.add_argument("--machine", default=platform.machine())
    f = sub.add_parser("fetch")
    f.add_argument("--pins", type=Path, default=DEFAULT_PINS)
    f.add_argument("--machine", default=platform.machine())
    f.add_argument("--dest", required=True, type=Path)
    f.add_argument("--bin", required=True, type=Path)
    f.add_argument("--attempts", type=int, default=6)
    f.add_argument("--base-delay", type=float, default=5.0)
    r = sub.add_parser("run")
    r.add_argument("--args", required=True)
    r.add_argument("--lychee", default="lychee")
    r.add_argument("--output", type=Path, default=Path("lychee/out.md"))
    r.add_argument("--no-fail", action="store_true")
    r.add_argument("--no-fail-if-empty", action="store_true")
    r.add_argument("--job-summary", action="store_true")
    a = ap.parse_args(argv)

    if a.cmd == "run":
        try:
            return run(a.args, lychee=a.lychee, output=a.output, fail=not a.no_fail,
                       fail_if_empty=not a.no_fail_if_empty, job_summary=a.job_summary)
        except ValueError as exc:  # shlex: unbalanced quotes; --output in args
            print(f"::error::lychee args: {exc}", file=sys.stderr)
            return 2
    try:
        pin = select(parse_pins(a.pins.read_text(encoding="utf-8")), a.machine)
    except (OSError, PinError) as exc:
        print(f"::error::{a.pins}: {exc}", file=sys.stderr)
        return 2
    if a.cmd == "key":
        print(f"version={pin.version}\ntarget={pin.target}\nsha256={pin.sha256}\nkey={pin.cache_key}")
        return 0
    try:
        fetch(pin, a.dest, a.bin, attempts=max(1, a.attempts), base_delay=a.base_delay)
    except (FetchError, OSError, tarfile.TarError) as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
