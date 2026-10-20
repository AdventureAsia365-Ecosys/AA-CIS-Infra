"""Consumer contract-copy hash guard (AA-826, data standards X7: CON-4, TST-6, DM-3.6).

The canonical cross-app contracts are the JSON Schemas in the root repo's `docs/contracts/` (AA-Ecosys, private).
App repos keep byte copies of the ones they produce or consume (AA-Booking `backend/app/contracts/`,
AA-TripPlanner-Web `backend/tests/contracts/`, …) and their CI validates or parses samples against them. A copy
edited in place silently forks the contract. This guard pins the sha256 of every canonical file in
`tools/contracts/contract_copies.json` and fails when:
  * a registered copy differs from the pinned hash (a modified consumer copy) or is missing on the repo's branch;
  * a consumer repo holds a file named like a pinned contract that the manifest does not register (unguarded copy);
  * the manifest is malformed (bad name, hash, repo, or a copy whose file name is not the contract's name);
  * with --canonical-dir (local workspace run): a pin differs from the canonical file, or a canonical contract
    file is not pinned.
A file in a consumer repo that only looks like a contract (`<name>.v<major>[.<minor>].json`, not pinned) is a
warning, not a failure.

CI cannot read the private root repo, so the pins are the producer side here: a new or changed contract file in
`docs/contracts/` is pinned in this repo (local run with --workspace proves the pins) before the consumers copy it.

Usage:
  python3 tools/contracts/check_contract_copies.py                         # CI: copies on each repo's main
  python3 tools/contracts/check_contract_copies.py --workspace ~/projects/AA-Ecosys   # local: canonical + checkouts
  python3 tools/contracts/check_contract_copies.py --ref AA-Booking=test/x  # read one repo at another ref
CONTRACT_COPY_REFS="AA-Booking=test/x[,Repo=ref]" does what --ref does (evidence runs from a workflow file).

Reads copies through the GitHub API (the app repos are public); GITHUB_TOKEN / GH_TOKEN only lifts the rate limit.
Standard library only.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Iterable, Optional

HERE = Path(__file__).resolve().parent
MANIFEST = HERE / "contract_copies.json"
CONTRACT_NAME_RE = re.compile(r"^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+\.v[0-9]+(\.[0-9]+)?\.json$")
SHA_RE = re.compile(r"^[0-9a-f]{64}$")
SKIP_DIRS = {".git", "node_modules", ".venv", "venv", "__pycache__", ".next", "dist", "build"}


class FetchError(RuntimeError):
    """GitHub could not be read (rate limit, network, outage); never a 404."""


# (repo, path, ref) -> bytes, or None when the file is not on that ref.
Fetcher = Callable[[str, str, str], Optional[bytes]]
# (repo, ref) -> every file path of the repo at ref.
Lister = Callable[[str, str], list]


@dataclass
class Report:
    errors: list = field(default_factory=list)
    warnings: list = field(default_factory=list)
    ok: list = field(default_factory=list)

    def fail(self, msg: str) -> None:
        self.errors.append(msg)

    def warn(self, msg: str) -> None:
        self.warnings.append(msg)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def load_manifest(path: Path = MANIFEST) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def check_manifest(m: dict, report: Report) -> None:
    if m.get("version") != 1:
        report.fail("manifest: version must be 1")
    repos = m.get("consumer_repos")
    if not isinstance(repos, list) or not repos or len(set(repos)) != len(repos):
        report.fail("manifest: consumer_repos must be a non-empty list without duplicates")
        repos = []
    contracts = m.get("contracts")
    if not isinstance(contracts, dict) or not contracts:
        report.fail("manifest: contracts must be a non-empty object")
        return
    for name, c in contracts.items():
        if not CONTRACT_NAME_RE.match(name):
            report.fail(f"manifest: {name}: not a contract file name <name>.v<major>[.<minor>].json")
        if not isinstance(c, dict) or set(c) != {"sha256", "copies"}:
            report.fail(f"manifest: {name}: needs exactly sha256 and copies")
            continue
        if not SHA_RE.match(str(c["sha256"])):
            report.fail(f"manifest: {name}: sha256 must be 64 lower-case hex characters")
        seen = set()
        for cp in c["copies"]:
            if not isinstance(cp, dict) or set(cp) != {"repo", "path"}:
                report.fail(f"manifest: {name}: each copy needs exactly repo and path")
                continue
            if cp["repo"] not in repos:
                report.fail(f"manifest: {name}: copy repo {cp['repo']} is not in consumer_repos")
            if Path(cp["path"]).name != name:
                report.fail(f"manifest: {name}: copy {cp['repo']}:{cp['path']} must keep the contract's file name")
            if (cp["repo"], cp["path"]) in seen:
                report.fail(f"manifest: {name}: copy {cp['repo']}:{cp['path']} listed twice")
            seen.add((cp["repo"], cp["path"]))


def check_canonical(m: dict, canonical_dir: Path, report: Report) -> None:
    """Local only (the root repo is private): each pin equals the canonical file, each canonical file is pinned."""
    contracts = m.get("contracts", {})
    files = {p.name: p for p in canonical_dir.glob("*.json") if CONTRACT_NAME_RE.match(p.name)}
    for name in sorted(set(files) - set(contracts)):
        report.fail(f"canonical {name}: not pinned in tools/contracts/contract_copies.json "
                    f"(sha256 {sha256(files[name].read_bytes())})")
    for name, c in sorted(contracts.items()):
        if name not in files:
            report.fail(f"canonical {name}: pinned but missing from {canonical_dir}")
            continue
        actual = sha256(files[name].read_bytes())
        if actual != c.get("sha256"):
            report.fail(f"canonical {name}: sha256 {actual} differs from the pin {c.get('sha256')}. A published "
                        f"contract is never edited in place (docs/contracts rule 2): add a new version file")
        else:
            report.ok.append(f"canonical {name}")


def check_copies(m: dict, fetch: Fetcher, list_files: Lister, refs: dict, report: Report,
                 discover: bool = True) -> None:
    branch = m.get("branch", "main")
    contracts = m.get("contracts", {})
    registered = {(cp["repo"], cp["path"]) for c in contracts.values() for cp in c.get("copies", [])
                  if isinstance(cp, dict) and {"repo", "path"} <= set(cp)}
    for name, c in sorted(contracts.items()):
        for cp in c.get("copies", []):
            repo, path = cp["repo"], cp["path"]
            ref = refs.get(repo, branch)
            where = f"{repo}@{ref}:{path}"
            try:
                data = fetch(repo, path, ref)
            except FetchError as e:
                report.fail(f"{where}: cannot read: {e}")
                continue
            if data is None:
                report.fail(f"{where}: registered copy of {name} not found. Remove it from the manifest in the "
                            f"same change that removes the copy, or restore the file")
                continue
            actual = sha256(data)
            if actual != c["sha256"]:
                report.fail(f"{where}: modified copy of {name}: sha256 {actual[:12]} != pinned "
                            f"{c['sha256'][:12]}. Copy the canonical AA-Ecosys docs/contracts/{name} byte for byte "
                            f"(cp, not an editor); a contract change is a new version file, never an in-place edit")
            else:
                report.ok.append(where)
    if not discover:
        return
    for repo in m.get("consumer_repos", []):
        ref = refs.get(repo, branch)
        try:
            paths = list_files(repo, ref)
        except FetchError as e:
            report.fail(f"{repo}@{ref}: cannot list files: {e}")
            continue
        for path in sorted(paths):
            base = path.rsplit("/", 1)[-1]
            if (repo, path) in registered:
                continue
            if base in contracts:
                report.fail(f"{repo}@{ref}:{path}: unregistered copy of {base}; add it to "
                            f"tools/contracts/contract_copies.json so the guard checks it")
            elif CONTRACT_NAME_RE.match(base):
                report.warn(f"{repo}@{ref}:{path}: looks like a contract file but {base} is not pinned")


# ── GitHub and local readers ─────────────────────────────────────────────────────────────────────────────────

def _token() -> str:
    return (os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN") or "").strip()


def _github_get(url: str, accept: str, attempts: int = 3) -> Optional[bytes]:
    token = _token()
    auths = ([token] if token else []) + [""]
    last = ""
    for attempt in range(attempts):
        for auth in auths:
            headers = {"Accept": accept, "X-GitHub-Api-Version": "2022-11-28",
                       "User-Agent": "aa-cis-infra-contract-copy-guard"}
            if auth:
                headers["Authorization"] = f"Bearer {auth}"
            try:
                with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as r:
                    return r.read()
            except urllib.error.HTTPError as e:
                if e.code == 404:
                    return None
                last = f"HTTP {e.code}"
                if e.code in (401, 403, 429):
                    continue
                if e.code < 500:
                    raise FetchError(f"GitHub API {last} for {url}") from None
                break
            except (urllib.error.URLError, TimeoutError, OSError) as e:
                last = f"network error {e}"
                break
        if attempt + 1 < attempts:
            time.sleep(2 * (attempt + 1))
    hint = "" if token else " (anonymous: 60 requests/hour; set GITHUB_TOKEN or GH_TOKEN)"
    raise FetchError(f"could not read {url}: {last}{hint}")


def github_fetcher(org: str) -> Fetcher:
    def fetch(repo: str, path: str, ref: str) -> Optional[bytes]:
        url = (f"https://api.github.com/repos/{org}/{repo}/contents/{urllib.parse.quote(path)}"
               f"?ref={urllib.parse.quote(ref, safe='')}")
        return _github_get(url, "application/vnd.github.raw")
    return fetch


def github_lister(org: str) -> Lister:
    def list_files(repo: str, ref: str) -> list:
        url = (f"https://api.github.com/repos/{org}/{repo}/git/trees/{urllib.parse.quote(ref, safe='')}"
               f"?recursive=1")
        body = _github_get(url, "application/vnd.github+json")
        if body is None:
            raise FetchError(f"ref {ref} not found in {org}/{repo}")
        tree = json.loads(body)
        if tree.get("truncated"):
            raise FetchError(f"tree listing of {org}/{repo}@{ref} is truncated: discovery is incomplete")
        return [e["path"] for e in tree.get("tree", []) if e.get("type") == "blob"]
    return list_files


def local_reader(roots: dict, fallback_fetch: Fetcher, fallback_list: Lister) -> tuple:
    """Repos in `roots` are read from a local checkout (working tree); the others from GitHub."""
    def fetch(repo: str, path: str, ref: str) -> Optional[bytes]:
        if repo not in roots:
            return fallback_fetch(repo, path, ref)
        p = roots[repo] / path
        return p.read_bytes() if p.is_file() else None

    def list_files(repo: str, ref: str) -> list:
        if repo not in roots:
            return fallback_list(repo, ref)
        out = []
        for dirpath, dirnames, filenames in os.walk(roots[repo]):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for f in filenames:
                out.append((Path(dirpath) / f).relative_to(roots[repo]).as_posix())
        return out
    return fetch, list_files


def parse_pairs(values: Iterable[str], what: str) -> dict:
    out = {}
    for v in values:
        for item in (x.strip() for x in v.split(",")):
            if not item:
                continue
            repo, sep, val = item.partition("=")
            if not sep or not repo or not val:
                raise SystemExit(f"{what} must look like Repo=value, got {item!r}")
            out[repo] = val
    return out


def run(m: dict, fetch: Fetcher, list_files: Lister, refs: dict, canonical_dir: Optional[Path] = None,
        discover: bool = True, out=None) -> int:
    out = out or sys.stdout
    report = Report()
    check_manifest(m, report)
    if not report.errors:
        if canonical_dir is not None:
            check_canonical(m, canonical_dir, report)
        check_copies(m, fetch, list_files, refs, report, discover=discover)
    gha = os.environ.get("GITHUB_ACTIONS") == "true"
    for line in report.ok:
        print(f"ok    {line}", file=out)
    for w in report.warnings:
        print(f"WARN  {w}", file=out)
        if gha:
            print(f"::warning::{w}", file=out)
    for e in report.errors:
        print(f"FAIL  {e}", file=out)
        if gha:
            print(f"::error::{e}", file=out)
    print(f"{len(report.ok)} ok, {len(report.warnings)} warning(s), {len(report.errors)} failure(s)", file=out)
    return 1 if report.errors else 0


def main(argv: Optional[list] = None, fetch: Optional[Fetcher] = None, list_files: Optional[Lister] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--manifest", default=str(MANIFEST))
    parser.add_argument("--canonical-dir", help="the root repo's docs/contracts (local runs: pins == canonical)")
    parser.add_argument("--local", action="append", default=[], metavar="REPO=DIR",
                        help="read this repo from a local checkout instead of GitHub")
    parser.add_argument("--ref", action="append", default=[], metavar="REPO=REF",
                        help="read this repo at REF instead of the manifest branch (also CONTRACT_COPY_REFS)")
    parser.add_argument("--workspace", help="AA-Ecosys workspace: canonical docs/contracts + apps/<repo> checkouts")
    parser.add_argument("--no-discover", action="store_true", help="skip the unregistered-copy scan")
    args = parser.parse_args(argv)

    m = load_manifest(Path(args.manifest))
    org = m.get("org", "AdventureAsia365-Ecosys")
    refs = parse_pairs([os.environ.get("CONTRACT_COPY_REFS", "")] + args.ref, "--ref / CONTRACT_COPY_REFS")
    roots = {k: Path(v) for k, v in parse_pairs(args.local, "--local").items()}
    canonical = Path(args.canonical_dir) if args.canonical_dir else None
    if args.workspace:
        ws = Path(args.workspace).expanduser()
        canonical = canonical or ws / "docs" / "contracts"
        for repo in m.get("consumer_repos", []):
            if repo not in roots and (ws / "apps" / repo).is_dir():
                roots[repo] = ws / "apps" / repo
    if canonical is not None and not canonical.is_dir():
        raise SystemExit(f"canonical dir {canonical} not found")
    fetch = fetch or github_fetcher(org)
    list_files = list_files or github_lister(org)
    if roots:
        fetch, list_files = local_reader(roots, fetch, list_files)
        refs.update({repo: "worktree" for repo in roots})      # label only: a local checkout is read as it is
    return run(m, fetch, list_files, refs, canonical_dir=canonical, discover=not args.no_discover)


if __name__ == "__main__":
    sys.exit(main())
