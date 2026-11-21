#!/usr/bin/env python3
"""Lean repo guard (AA-1161): refuse screenshots, build artifacts and binaries that do not belong in git.

Git history keeps every committed blob for ever, and shrinking a public repo afterwards needs a history rewrite and a
force push (S285: the root repo had reached 826 MB, 662 MB of it audit screenshots; AA-CIS-Infra carried ~100 MB of
Lambda build zips). This guard runs at push time (each repo's scripts/pre-push.sh) and on every pull request (the
repo's guard workflow), on the files a change ADDS or CHANGES between a base and a head:

  image-size     a raster image (PNG, JPEG, GIF, WebP, BMP, TIFF, HEIC, AVIF, ICO) over IMAGE_MAX_BYTES (500 KiB);
  image-total    raster images adding up to more than IMAGE_TOTAL_MAX_BYTES (10 MiB) in the range;
  dist-zip       a *.zip under a dist/ folder (a build artifact: build it in CI or Terraform, store it in S3/ECR);
  executable     an ELF, Mach-O or PE (Windows) executable or library, whatever its name;
  file-size      any file over FILE_MAX_BYTES (5 MiB).

A path listed in the repo's `.lean-allow` file with a reason is exempt from every rule (and does not count towards
image-total). One entry per line: `<path or glob> <reason>`; a line starting with `#` is a comment; `*` also
matches `/`. An entry
without a reason, or a catch-all glob (`*`, `**`, `**/*`), is a configuration error (exit 2).

SVG is text: it is checked by file-size only (tools/docs/check_images.py caps the published ones). A file whose blob
does not change (a pure rename) and a deleted file are never checked: they add nothing to history.

The limits are the tech lead's repo policy (S285, AA-1161), the same in every repo; change them here, in the root
copy, then copy this file byte-identical into every repo (tools/repo/README.md).

Usage:
  python3 tools/repo/lean_guard.py --base origin/main [--head HEAD]
  python3 tools/repo/lean_guard.py --base <sha> --head <sha> --github   (CI: ::error annotations)
  --allow-missing-base   exit 0 with a note when the base ref is not there (pre-push without a fetch; CI never)
  --prefetch             in a blobless (partial) clone, fetch the changed blobs in one round trip first (CI)

Exit codes: 0 clean, 1 at least one refused file, 2 usage, git or .lean-allow error.
Stdlib only, Python 3.9+, so every repo runs it without installing anything.
"""

from __future__ import annotations

import argparse
import fnmatch
import os
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import PurePosixPath

KIB = 1024
MIB = 1024 * KIB
IMAGE_MAX_BYTES = 500 * KIB
IMAGE_TOTAL_MAX_BYTES = 10 * MIB
FILE_MAX_BYTES = 5 * MIB
HEADER_BYTES = 4096

RASTER_SUFFIXES = frozenset(
    {".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".tif", ".tiff", ".heic", ".heif", ".avif", ".ico"}
)
ALLOW_FILE = ".lean-allow"
CATCH_ALL = frozenset({"*", "**", "**/*", "*/*", "/*", "./*"})
COMPRESS_HINT = (
    "compress it with `python3 tools/docs/compress_images.py <file>` (AA-Ecosys root repo; Pillow: PNG to 256 "
    "colours, JPEG quality 75, names kept), or keep the full image in the private S3 archive "
    "(archive/repo-media/, docs/ops/repo-media-archive.md) or the audit-assets prefix and link it from the page"
)
HINTS = {
    "image-size": COMPRESS_HINT,
    "image-total": (
        "commit at most ~5-10 key screenshots per change (~5-10 MB); move the full set to the private S3 "
        "archive (archive/repo-media/) or audit-assets prefix and link it (ASSETS.md in the audit folder)"
    ),
    "dist-zip": (
        "a build artifact: build it in CI or Terraform (archive_file) and store it in S3/ECR/workflow artifacts; "
        "add the folder to .gitignore"
    ),
    "executable": (
        "binaries never go into git: download them in CI with a pinned sha256 (.github/actions/release-bin) or "
        "keep them outside the repo"
    ),
    "file-size": (
        "keep it out of git (S3, Drive or a workflow artifact); if it truly belongs in the repo, add "
        f"`<path> <reason>` to {ALLOW_FILE}"
    ),
}


class GuardError(Exception):
    """A usage, git or configuration problem: exit 2."""


@dataclass(frozen=True)
class AllowEntry:
    pattern: str
    reason: str
    line: int


@dataclass(frozen=True)
class Change:
    path: str
    oid: str
    size: int
    header: bytes


@dataclass
class Report:
    checked: int = 0
    image_bytes: int = 0
    findings: list[tuple[str, str, str]] = field(default_factory=list)  # (path, rule, message)
    allowed: list[tuple[str, str]] = field(default_factory=list)  # (path, reason)


# --- pure rules ------------------------------------------------------------------------------------------------------


def human(n: int) -> str:
    if n >= MIB:
        return f"{n / MIB:.1f} MiB"
    return f"{n / KIB:.0f} KiB"


def binary_kind(header: bytes) -> str | None:
    """The executable format a file starts with, or None. Reads only the first HEADER_BYTES bytes."""
    if header[:4] == b"\x7fELF":
        return "ELF"
    if header[:4] in (b"\xfe\xed\xfa\xce", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe", b"\xcf\xfa\xed\xfe"):
        return "Mach-O"
    # A universal (fat) Mach-O counts its architectures in bytes 4-8 (a handful); a Java class file shares the magic
    # and has its class-file version (major >= 45) in the same bytes.
    fat = header[:4] in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf")
    if fat and len(header) >= 8 and int.from_bytes(header[4:8], "big") < 45:
        return "Mach-O universal"
    if header[:2] == b"MZ" and len(header) >= 64:
        pe = int.from_bytes(header[60:64], "little")
        if 0 < pe <= len(header) - 4 and header[pe : pe + 4] == b"PE\x00\x00":
            return "PE"
    return None


def is_raster(path: str) -> bool:
    return PurePosixPath(path).suffix.lower() in RASTER_SUFFIXES


def is_dist_zip(path: str) -> bool:
    p = PurePosixPath(path)
    return p.suffix.lower() == ".zip" and "dist" in p.parts[:-1]


def parse_allow(text: str) -> list[AllowEntry]:
    entries: list[AllowEntry] = []
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(None, 1)
        pattern = parts[0].removeprefix("./")
        reason = parts[1].strip() if len(parts) > 1 else ""
        if not reason:
            raise GuardError(f"{ALLOW_FILE}:{n}: '{parts[0]}' has no reason; write `<path> <why it belongs in git>`")
        if pattern in CATCH_ALL:
            raise GuardError(f"{ALLOW_FILE}:{n}: '{parts[0]}' would allow every file; name the files")
        entries.append(AllowEntry(pattern, reason, n))
    return entries


def allowed_by(path: str, entries: list[AllowEntry]) -> AllowEntry | None:
    for e in entries:
        if path == e.pattern or fnmatch.fnmatchcase(path, e.pattern):
            return e
    return None


def evaluate(changes: list[Change], allow: list[AllowEntry]) -> Report:
    rep = Report()
    for c in changes:
        rep.checked += 1
        entry = allowed_by(c.path, allow)
        if entry is not None:
            rep.allowed.append((c.path, entry.reason))
            continue
        if is_raster(c.path):
            rep.image_bytes += c.size
            if c.size > IMAGE_MAX_BYTES:
                rep.findings.append((c.path, "image-size", f"image is {human(c.size)}, the limit is {human(IMAGE_MAX_BYTES)}"))
        if is_dist_zip(c.path):
            rep.findings.append((c.path, "dist-zip", f"build artifact under dist/ ({human(c.size)})"))
        kind = binary_kind(c.header)
        if kind:
            rep.findings.append((c.path, "executable", f"{kind} executable or library ({human(c.size)})"))
        flagged = any(f[0] == c.path for f in rep.findings)  # one finding per file is enough to refuse it
        if c.size > FILE_MAX_BYTES and not flagged:
            rep.findings.append((c.path, "file-size", f"file is {human(c.size)}, the limit is {human(FILE_MAX_BYTES)}"))
    if rep.image_bytes > IMAGE_TOTAL_MAX_BYTES:
        rep.findings.append(
            ("", "image-total",
             f"images in this change add {human(rep.image_bytes)}, the limit is {human(IMAGE_TOTAL_MAX_BYTES)} per change")
        )
    return rep


# --- git -------------------------------------------------------------------------------------------------------------


def git(repo: str, *args: str, input_bytes: bytes | None = None, env: dict | None = None) -> bytes:
    proc = subprocess.run(
        ["git", "-C", repo, *args], input=input_bytes, capture_output=True, env=env, check=False
    )
    if proc.returncode != 0:
        msg = proc.stderr.decode("utf-8", "replace").strip().splitlines()
        raise GuardError(f"git {' '.join(args[:3])} failed: {msg[-1] if msg else proc.returncode}")
    return proc.stdout


def ref_exists(repo: str, ref: str) -> bool:
    proc = subprocess.run(
        ["git", "-C", repo, "rev-parse", "-q", "--verify", f"{ref}^{{commit}}"], capture_output=True, check=False
    )
    return proc.returncode == 0


def parse_raw_diff(raw: bytes) -> list[tuple[str, str]]:
    """(path, new blob oid) of every added / changed regular file in `git diff --raw -z` output.

    A rename or copy whose blob is unchanged, a symlink, a submodule and a deletion are left out."""
    out: list[tuple[str, str]] = []
    items = raw.split(b"\0")
    i = 0
    while i < len(items):
        head = items[i]
        if not head.startswith(b":"):
            i += 1
            continue
        meta = head[1:].decode().split()
        _old_mode, new_mode, old_oid, new_oid, status = meta[:5]
        if status[0] in "RC":
            path = items[i + 2].decode("utf-8", "surrogateescape")
            i += 3
        else:
            path = items[i + 1].decode("utf-8", "surrogateescape")
            i += 2
        if status[0] == "D" or not new_mode.startswith("100"):
            continue
        if status[0] in "RC" and old_oid == new_oid:
            continue
        out.append((path, new_oid))
    return out


def changed_blobs(repo: str, base: str, head: str) -> list[tuple[str, str]]:
    # Three dots: what the change adds on top of where it forked (the PR view). A shallow clone without the merge
    # base falls back to the two trees.
    merge_base = subprocess.run(["git", "-C", repo, "merge-base", base, head], capture_output=True, check=False)
    spec = [f"{base}...{head}"] if merge_base.returncode == 0 else [base, head]
    raw = git(repo, "-c", "core.quotePath=false", "diff", "--raw", "-z", "--no-abbrev", "--find-renames=100%",
              "--diff-filter=ACMRT", *spec)
    return parse_raw_diff(raw)


def prefetch(repo: str, oids: list[str]) -> None:
    """In a partial (blobless) clone, fetch the blobs to read in one round trip instead of one lazy fetch each.

    Every oid is asked for (no "is it missing" probe: before git 2.44 that probe itself fetches lazily, one object at a
    time). A failed fetch is ignored: git still fetches a missing blob lazily when it is read."""
    promisor = subprocess.run(["git", "-C", repo, "config", "--get", "remote.origin.promisor"],
                              capture_output=True, text=True, check=False)
    if promisor.stdout.strip() != "true" or not oids:
        return
    subprocess.run(["git", "-C", repo, "-c", "fetch.negotiationAlgorithm=noop", "fetch", "--no-tags",
                    "--no-write-fetch-head", "--recurse-submodules=no", "--filter=blob:none", "--stdin", "origin"],
                   input="\n".join(oids) + "\n", capture_output=True, text=True, check=False)


def blob_sizes(repo: str, oids: list[str]) -> dict[str, int]:
    if not oids:
        return {}
    out = git(repo, "cat-file", "--batch-check=%(objectname) %(objectsize)",
              input_bytes=("\n".join(oids) + "\n").encode())
    sizes: dict[str, int] = {}
    for line in out.decode().splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1].isdigit():
            sizes[parts[0]] = int(parts[1])
    return sizes


def blob_header(repo: str, oid: str) -> bytes:
    proc = subprocess.Popen(["git", "-C", repo, "cat-file", "blob", oid], stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL)
    assert proc.stdout is not None
    buf = b""
    while len(buf) < HEADER_BYTES:
        chunk = proc.stdout.read(HEADER_BYTES - len(buf))
        if not chunk:
            break
        buf += chunk
    proc.stdout.close()
    if proc.poll() is None:
        proc.kill()
    proc.wait()
    return buf


def collect(repo: str, base: str, head: str, do_prefetch: bool = False) -> list[Change]:
    pairs = changed_blobs(repo, base, head)
    oids = sorted({oid for _, oid in pairs})
    if do_prefetch:
        prefetch(repo, oids)
    sizes = blob_sizes(repo, oids)
    headers = {oid: blob_header(repo, oid) for oid in oids}
    return [Change(path, oid, sizes.get(oid, 0), headers.get(oid, b"")) for path, oid in pairs]


def read_allow(repo: str, head: str) -> list[AllowEntry]:
    """The .lean-allow of the head commit (what is pushed or merged), else of the working tree."""
    proc = subprocess.run(["git", "-C", repo, "show", f"{head}:{ALLOW_FILE}"], capture_output=True, check=False)
    if proc.returncode == 0:
        return parse_allow(proc.stdout.decode("utf-8", "replace"))
    path = os.path.join(repo, ALLOW_FILE)
    if os.path.isfile(path):
        with open(path, encoding="utf-8") as fh:
            return parse_allow(fh.read())
    return []


# --- output ----------------------------------------------------------------------------------------------------------


def render(rep: Report, base: str, github: bool) -> list[str]:
    lines: list[str] = []
    for path, reason in rep.allowed:
        lines.append(f"allowed  {path} ({ALLOW_FILE}: {reason})")
    for path, rule, msg in rep.findings:
        where = path or "(this change)"
        lines.append(f"REFUSED  {where}: {rule}: {msg}")
        lines.append(f"         fix: {HINTS[rule]}")
        if github:
            text = f"{msg}. Fix: {HINTS[rule]}".replace("%", "%25").replace("\n", " ")
            lines.append(f"::error {'file=' + path + ',' if path else ''}title=Lean guard {rule}::{text}")
    verdict = f"{len(rep.findings)} refused" if rep.findings else "ok"
    lines.append(
        f"lean guard: {rep.checked} added/changed file(s) vs {base}, images {human(rep.image_bytes)}"
        f" (limit {human(IMAGE_TOTAL_MAX_BYTES)}); {verdict}"
    )
    if rep.findings:
        lines.append("Policy: AA-1161 (screenshots compressed and few, build artifacts and binaries never in git).")
    return lines


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    ap.add_argument("--base", required=True, help="base ref (origin/main, origin/master or a sha)")
    ap.add_argument("--head", default="HEAD", help="head ref (default HEAD)")
    ap.add_argument("--repo", default=".", help="repository directory (default: the current one)")
    ap.add_argument("--allow-missing-base", action="store_true", help="base not found: note and exit 0")
    ap.add_argument("--prefetch", action="store_true", help="fetch the changed blobs at once in a partial clone")
    ap.add_argument("--github", action="store_true", help="also print GitHub ::error annotations")
    args = ap.parse_args(argv)
    try:
        repo = git(args.repo, "rev-parse", "--show-toplevel").decode().strip()
        if not ref_exists(repo, args.base):
            if args.allow_missing_base:
                print(f"lean guard: base {args.base} not found (git fetch origin?); skipped here, CI still checks it")
                return 0
            raise GuardError(f"base {args.base} not found")
        if not ref_exists(repo, args.head):
            raise GuardError(f"head {args.head} not found")
        allow = read_allow(repo, args.head)
        rep = evaluate(collect(repo, args.base, args.head, args.prefetch), allow)
    except GuardError as e:
        print(f"lean guard: error: {e}", file=sys.stderr)
        return 2
    for line in render(rep, args.base, args.github):
        print(line)
    return 1 if rep.findings else 0


if __name__ == "__main__":
    sys.exit(main())
