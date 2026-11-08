#!/usr/bin/env python3
"""A pinned release binary (syft, trivy, actionlint, oasdiff, ...) from a cached, hash-checked copy (S273, AA-1024).

On 08/11/2026 GitHub throttled unauthenticated release downloads: lychee and the spaCy wheel moved to cached,
sha256-pinned copies that day, but the other CI tools still came from a bare download on every run (anchore/sbom-action
fetched syft through an install script: "The Syft installer failed to install v1.54.0", HTTP 504; trivy-action's
setup-trivy, the actionlint and oasdiff `curl` steps). This script is the one path for all of them:

  key    prints `tool=`, `version=`, `arch=`, `sha256=`, `file=` and `key=` lines for `$GITHUB_OUTPUT`, from the pin file
         (.github/actions/release-bin/pins.txt) and this machine's platform: the cache key moves only when the pin moves.
  fetch  puts the pinned release file in --dest, checked against the pinned sha256: a verified copy already there (a
         cache hit) is kept; else it is downloaded (an authenticated `gh release download` for a github.com release
         asset when GH_TOKEN is set, then plain HTTPS over HTTP/1.1) with retries and backoff, and checked. Bytes that
         never match the pin fail the step: the pin is never relaxed. Then the pinned member (only that file) is
         extracted from the .tar.gz into --bin, mode 0755; a pin whose member is `-` keeps the file as is (a .deb the
         job installs itself). Prints `path=` (the binary, or the verified file) for `$GITHUB_OUTPUT`; every log line,
         warning and error goes to stderr, because the action sends stdout into `$GITHUB_OUTPUT` and a line that is not
         `name=value` there fails the step.

Pin line: `<tool> <version> <arch> <sha256> <url> <member>`; arch is x86_64 or aarch64; the url names the version.
Used by .github/actions/release-bin (actions/cache keyed on tool + version + arch + sha256). Stdlib only. The same file
in the root repo, AA-CIS-App, AA-Booking, AA-Partner, AA-TripPlanner-Web and AA-CIS-Infra: change it in all of them
in the same wave (with pins.txt).
Run: python3 .github/scripts/release_bin.py key --tool NAME [--pins FILE] [--machine ARCH]
     python3 .github/scripts/release_bin.py fetch --tool NAME --dest DIR --bin DIR [--pins FILE] [--attempts N]
       [--base-delay S]
Exit 0 = done, 1 = the file could not be fetched or verified, 2 = a bad pin file, tool or platform.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import platform
import random
import re
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
DEFAULT_PINS = HERE.parent / "actions" / "release-bin" / "pins.txt"
PIN_LINE = re.compile(r"^(?P<tool>[a-z0-9][a-z0-9-]*)\s+(?P<version>v?\d+(?:\.\d+){1,3})\s+(?P<arch>x86_64|aarch64)"
                      r"\s+(?P<sha>[0-9a-f]{64})\s+(?P<url>https://\S+)\s+(?P<member>-|[A-Za-z0-9._-]+)\s*$")
MACHINES = {"x86_64": "x86_64", "amd64": "x86_64", "x64": "x86_64", "aarch64": "aarch64", "arm64": "aarch64"}
CHUNK = 1 << 16
USER_AGENT = "aa-ci-release-bin/1"


def log_stderr(msg: str) -> None:
    """Log lines, ::warning:: and ::error:: annotations: stderr only (stdout is the `$GITHUB_OUTPUT` channel)."""
    print(msg, file=sys.stderr)


class PinError(ValueError):
    """The pin file is malformed, or has no pin for this tool and platform."""


class FetchError(RuntimeError):
    """The file could not be fetched with the pinned sha256, or holds no pinned member."""


@dataclass(frozen=True)
class Pin:
    tool: str
    version: str
    arch: str
    sha256: str
    url: str
    member: str

    @property
    def filename(self) -> str:
        return f"{self.tool}-{self.version}-{self.arch}-{self.url.rsplit('/', 1)[-1]}"

    @property
    def cache_key(self) -> str:
        return f"{self.tool}-{self.version}-{self.arch}-{self.sha256}"


def parse_pins(text: str) -> list[Pin]:
    """Pin lines (comments and blank lines skipped): one version per tool, one line per tool and arch."""
    pins: list[Pin] = []
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        m = PIN_LINE.match(line)
        if not m:
            raise PinError(f"line {lineno}: expected '<tool> <version> <x86_64|aarch64> <64 hex sha256> <https url> "
                           f"<member|->', got {line!r}")
        pin = Pin(*(m.group(k) for k in ("tool", "version", "arch", "sha", "url", "member")))
        if pin.version.lstrip("v") not in pin.url:
            raise PinError(f"line {lineno}: the url does not name version {pin.version} (a half-moved pin?)")
        pins.append(pin)
    if not pins:
        raise PinError("no pin")
    for tool in {p.tool for p in pins}:
        mine = [p for p in pins if p.tool == tool]
        if len({p.version for p in mine}) != 1:
            raise PinError(f"{tool}: more than one version pinned: {sorted({p.version for p in mine})}")
        if len({p.arch for p in mine}) != len(mine):
            raise PinError(f"{tool}: an arch is pinned twice")
    return pins


def arch_for(machine: str) -> str:
    arch = MACHINES.get(machine.lower())
    if arch is None:
        raise PinError(f"no build pinned for machine {machine!r}")
    return arch


def select(pins: list[Pin], tool: str, machine: str) -> Pin:
    arch = arch_for(machine)
    mine = [p for p in pins if p.tool == tool]
    if not mine:
        raise PinError(f"no pin for tool {tool!r} (pinned: {', '.join(sorted({p.tool for p in pins}))})")
    for pin in mine:
        if pin.arch == arch:
            return pin
    raise PinError(f"{tool}: no pin for {arch} (pinned: {', '.join(p.arch for p in mine)})")


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
        log_stderr(f"::warning::authenticated gh download failed ({type(exc).__name__}); trying plain HTTPS")
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    fd, tmp = tempfile.mkstemp(dir=dest.parent, prefix=".part-")
    try:
        with os.fdopen(fd, "wb") as out, urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310 (pinned)
            shutil.copyfileobj(resp, out, CHUNK)
        os.replace(tmp, dest)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def download_verified(pin: Pin, dest: Path, *, attempts: int = 6, base_delay: float = 5.0, timeout: float = 120.0,
                      download=_download, sleep=time.sleep, log=log_stderr) -> None:
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


def extract_member(archive: Path, member: str, bin_dir: Path) -> Path:
    """Copy the archive's `member` file (top level or one folder down) to bin_dir/member, mode 0755; nothing else."""
    bin_dir.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive, "r:gz") as tar:
        found = [m for m in tar.getmembers() if m.isfile() and m.name.lstrip("./").count("/") <= 1
                 and os.path.basename(m.name) == member]
        if not found:
            raise FetchError(f"{archive.name}: no {member} file in the archive (did its layout change?)")
        src = tar.extractfile(found[0])
        if src is None:
            raise FetchError(f"{archive.name}: cannot read {found[0].name}")
        fd, tmp = tempfile.mkstemp(dir=bin_dir, prefix=f".{member}-")
        with os.fdopen(fd, "wb") as out, src:
            shutil.copyfileobj(src, out, CHUNK)
    os.chmod(tmp, 0o755)
    target = bin_dir / member
    os.replace(tmp, target)
    return target


def fetch(pin: Pin, dest: Path, bin_dir: Path, *, log=log_stderr, **download_kw) -> Path:
    """The pinned file, verified, in `dest`; its member in `bin_dir`. Returns the binary (or, member '-', the file)."""
    dest.mkdir(parents=True, exist_ok=True)
    archive = dest / pin.filename
    if verified(archive, pin.sha256):
        log(f"{pin.filename}: verified local copy (cache hit)")
    else:
        archive.unlink(missing_ok=True)
        log(f"{pin.filename}: downloading {pin.url}")
        download_verified(pin, archive, log=log, **download_kw)
        log(f"{pin.filename}: downloaded, sha256 verified")
    if pin.member == "-":
        return archive
    binary = extract_member(archive, pin.member, bin_dir)
    log(f"{pin.tool} {pin.version} ({pin.arch}) installed at {binary}")
    return binary


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("key", "fetch"):
        p = sub.add_parser(name)
        p.add_argument("--tool", required=True)
        p.add_argument("--pins", type=Path, default=DEFAULT_PINS)
        p.add_argument("--machine", default=platform.machine())
        if name == "fetch":
            p.add_argument("--dest", required=True, type=Path)
            p.add_argument("--bin", required=True, type=Path)
            p.add_argument("--attempts", type=int, default=6)
            p.add_argument("--base-delay", type=float, default=5.0)
    a = ap.parse_args(argv)
    try:
        pin = select(parse_pins(a.pins.read_text(encoding="utf-8")), a.tool, a.machine)
    except (OSError, PinError) as exc:
        log_stderr(f"::error::{a.pins}: {exc}")
        return 2
    if a.cmd == "key":
        print(f"tool={pin.tool}\nversion={pin.version}\narch={pin.arch}\nsha256={pin.sha256}\nfile={pin.filename}\n"
              f"key={pin.cache_key}")
        return 0
    try:
        path = fetch(pin, a.dest, a.bin, attempts=max(1, a.attempts), base_delay=a.base_delay,
                     log=log_stderr)
    except (FetchError, OSError, tarfile.TarError) as exc:
        log_stderr(f"::error::{exc}")
        return 1
    print(f"path={path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
