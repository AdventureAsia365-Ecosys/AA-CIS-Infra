"""Checks that every DB Migrate copy in db/migrations/<owner>/ matches its owner repo's main (AA-807).

db/migrations/<owner>/ holds copies of migrations that the owner repo reviewed and merged
(AA-Ecosys docs/database/schema-ownership.md rule 3). This guard fails when a copy:
  * has a path DB Migrate would refuse (owner dir + NNN_name.sql, same rule as db-migrate.yml);
  * does not register its own version key in shared.schema_versions, or registers a key outside
    its owner's prefix (CIS `NNN`, TripPlanner `tp-NNN`, Booking `bk-NNN`, roles `rl-NNN`, rule 4);
  * is not on the owner repo's main yet (migration flow D8: the migration-only PR merges in the
    owner repo first, then the Infra copy);
  * differs from the owner's main by even one byte.
db/migrations/roles/ (X1 role bootstrap, extensions, undo files; key `rl-NNN`) is Infra-native: no
owner repo to compare with, so only the path and the registration are checked.
CODE_COPIES: code files Infra runs as byte copies of an owner repo's file (the X2 RLS catalogue rules,
canonical in AA-CIS-App). Same byte compare, no registration; `--all` checks them too. The registry of
owners is db/owners.yaml; OWNERS and PATH_RE mirror it (db/tests/test_owners_registry.py).

Usage:
  python3 db/check_migration_copies.py db/migrations/cis/228_x.sql [...]   # given files
  python3 db/check_migration_copies.py --all                                # every copy

Reads the owner files through the GitHub contents API (the app repos are public). GITHUB_TOKEN (or
GH_TOKEN) is used when set (higher rate limit); without it, or if GitHub rejects it, the call is
anonymous. Rate limits, network errors and 5xx are retried, then reported as a FAIL for that file
(never a traceback that stops the run).
Only the standard library is used, so CI needs no install step.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import re
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional

ORG = "AdventureAsia365-Ecosys"
BRANCH = "main"
MIGRATIONS_DIR = "db/migrations"
OWNER_FIRST = "merge the migration-only PR in the owner repo first"


@dataclass(frozen=True)
class Owner:
    repo: str            # GitHub repo under ORG
    source_dir: str      # migrations folder inside the owner repo
    key_prefix: str      # shared.schema_versions key prefix
    native: bool = False  # Infra-native (roles/): no owner repo copy to compare


# db/owners.yaml (dir, repo, path, key_prefix); db-migrate.yml computes the same prefixes.
OWNERS: dict[str, Owner] = {
    "cis": Owner("AA-CIS-App", "api/migrations", ""),
    "tripplanner": Owner("AA-TripPlanner-Web", "migrations", "tp-"),
    "booking": Owner("AA-Booking", "migrations", "bk-"),
    "roles": Owner("AA-CIS-Infra", "db/migrations/roles", "rl-", native=True),
}

# Code copies: Infra path -> (owner repo, path on its main). The owner file is canonical (it is what CI runs at
# PR time); the Infra copy is refreshed byte for byte after the owner PR merges, like a migration copy.
CODE_COPIES: dict[str, tuple[str, str]] = {
    "db/rls_catalogue_rules.py": ("AA-CIS-App", "tests/integration/rls_catalogue_rules.py"),
}

# Same shape db-migrate.yml accepts at dispatch time.
PATH_RE = re.compile(r"^db/migrations/(cis|tripplanner|booking|roles)/([0-9]{3})_[a-z0-9_]+\.sql$")
INSERT_RE = re.compile(r"INSERT\s+INTO\s+shared\.schema_versions\b(.*?);", re.IGNORECASE | re.DOTALL)
KEY_RE = re.compile(r"\(\s*'([^']*)'\s*,")

class FetchError(RuntimeError):
    """The owner file could not be read (rate limit, network, GitHub outage); not a 404."""


# Returns the owner file's bytes, or None when the file is not on that branch (HTTP 404);
# raises FetchError when GitHub cannot be read.
Fetcher = Callable[[str, str], Optional[bytes]]


def registered_keys(sql: str) -> list[str]:
    """Version keys a migration inserts into shared.schema_versions (first value of each row)."""
    keys: list[str] = []
    for stmt in INSERT_RE.finditer(sql):
        keys.extend(KEY_RE.findall(stmt.group(1)))
    return keys


def check_registration(owner_name: str, number: str, sql: str) -> list[str]:
    owner = OWNERS[owner_name]
    expected = f"{owner.key_prefix}{number}"
    key_shape = re.compile(rf"^{re.escape(owner.key_prefix)}[0-9]{{3}}$")
    keys = registered_keys(sql)
    errors = []
    if expected not in keys:
        errors.append(
            f"does not register its version '{expected}' in shared.schema_versions "
            f"(found: {keys or 'none'})"
        )
    wrong = [k for k in keys if not key_shape.match(k)]
    if wrong:
        shape = f"{owner.key_prefix}NNN" if owner.key_prefix else "NNN (no prefix)"
        errors.append(f"registers {wrong}, outside the {owner_name} key prefix {shape}")
    return errors


def first_difference(a: bytes, b: bytes) -> str:
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            line = a[:i].count(b"\n") + 1
            return f"first difference at byte {i} (line {line})"
    return f"one file is a prefix of the other ({len(a)} vs {len(b)} bytes)"


def check_code_copy(rel_path: str, repo_root: Path, fetch: Fetcher) -> list[str]:
    """A CODE_COPIES file: byte-identical to its owner file on main (no registration to check)."""
    repo, source_path = CODE_COPIES[rel_path]
    local = (repo_root / rel_path).read_bytes()
    where = f"{ORG}/{repo}@{BRANCH}:{source_path}"
    try:
        upstream = fetch(repo, source_path)
    except FetchError as e:
        return [f"cannot compare with {where}: {e}"]
    if upstream is None:
        return [f"not found on {where} — merge the owner PR first, then copy the file here"]
    if upstream != local:
        return [f"differs from {where}: {first_difference(local, upstream)}; copy the owner file byte for byte "
                f"(cp, not an editor), the owner repo's file is canonical"]
    return []


def check_file(rel_path: str, repo_root: Path, fetch: Fetcher) -> list[str]:
    """Returns the problems found for one copy; empty means it is fine."""
    if rel_path in CODE_COPIES:
        return check_code_copy(rel_path, repo_root, fetch)
    m = PATH_RE.match(rel_path)
    if not m:
        return [
            "path must be db/migrations/<cis|tripplanner|booking|roles>/NNN_lowercase_name.sql "
            "(the shape DB Migrate accepts)"
        ]
    owner_name, number = m.group(1), m.group(2)
    owner = OWNERS[owner_name]
    local = (repo_root / rel_path).read_bytes()

    try:
        errors = check_registration(owner_name, number, local.decode("utf-8"))
    except UnicodeDecodeError:
        errors = ["is not valid UTF-8"]
    if owner.native:
        return errors        # Infra-native: reviewed in this repo, nothing upstream to compare

    source_path = f"{owner.source_dir}/{Path(rel_path).name}"
    where = f"{ORG}/{owner.repo}@{BRANCH}:{source_path}"
    try:
        upstream = fetch(owner.repo, source_path)
    except FetchError as e:
        errors.append(f"cannot compare with {where}: {e}")
        return errors
    if upstream is None:
        errors.append(
            f"not found on {where} — {OWNER_FIRST}, then open this copy PR or re-run this check "
            f"(flow D8)"
        )
    elif upstream != local:
        errors.append(
            f"differs from {where}: {first_difference(local, upstream)}; "
            f"sha256 copy={hashlib.sha256(local).hexdigest()[:12]} "
            f"owner={hashlib.sha256(upstream).hexdigest()[:12]}. Copy the owner file byte for byte "
            f"(cp, not an editor). If the owner changed a file that is already copied: DB Migrate never "
            f"re-runs an applied version, so if it is applied, revert the owner edit and ship the "
            f"change as a new migration; if it is not applied yet, {OWNER_FIRST} and re-copy"
        )
    return errors


def _token() -> str:
    # GITHUB_TOKEN in Actions; GH_TOKEN or GITHUB_TOKEN locally (e.g. GH_TOKEN=$(gh auth token)).
    return (os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN") or "").strip()


def github_fetch(repo: str, path: str, attempts: int = 3) -> Optional[bytes]:
    url = f"https://api.github.com/repos/{ORG}/{repo}/contents/{path}?ref={BRANCH}"
    token = _token()
    auths = ([token] if token else []) + [""]
    last = ""
    for attempt in range(attempts):
        for auth in auths:
            headers = {
                "Accept": "application/vnd.github.raw",
                "X-GitHub-Api-Version": "2022-11-28",
                "User-Agent": "aa-cis-infra-migration-copy-guard",
            }
            if auth:
                headers["Authorization"] = f"Bearer {auth}"
            try:
                req = urllib.request.Request(url, headers=headers)
                with urllib.request.urlopen(req, timeout=30) as r:
                    return r.read()
            except urllib.error.HTTPError as e:
                if e.code == 404:
                    return None
                last = f"HTTP {e.code}"
                if e.code in (401, 403, 429):
                    continue            # token refused or rate limited: try anonymous / next round
                if e.code < 500:
                    raise FetchError(f"GitHub API {last} for {repo}:{path}") from None
                break                   # 5xx: back off and retry
            except (urllib.error.URLError, TimeoutError, OSError) as e:
                last = f"network error {e}"
                break
        if attempt + 1 < attempts:
            time.sleep(2 * (attempt + 1))
    hint = "" if token else " (anonymous: 60 requests/hour; set GITHUB_TOKEN or GH_TOKEN)"
    raise FetchError(f"could not read {repo}:{path} from GitHub: {last}{hint}")


def all_copies(repo_root: Path) -> list[str]:
    base = repo_root / MIGRATIONS_DIR
    files = [p.relative_to(repo_root).as_posix() for p in base.rglob("*") if p.is_file()] if base.is_dir() else []
    return sorted(files + [rel for rel in CODE_COPIES if (repo_root / rel).is_file()])


def run(paths: list[str], repo_root: Path, fetch: Fetcher, out=sys.stdout) -> int:
    failed = checked = 0
    for rel in paths:
        rel = rel.strip()
        if not rel:
            continue
        if not (repo_root / rel).is_file():
            print(f"skip  {rel} (deleted in this change)", file=out)
            continue
        checked += 1
        errors = check_file(rel, repo_root, fetch)
        if errors:
            failed += 1
            for err in errors:
                print(f"FAIL  {rel}: {err}", file=out)
                if os.environ.get("GITHUB_ACTIONS") == "true":
                    print(f"::error file={rel}::{err}", file=out)
        else:
            print(f"ok    {rel}", file=out)
    print(f"{checked} file(s) checked, {failed} failed", file=out)
    return 1 if failed else 0


def main(argv: Optional[list[str]] = None, fetch: Fetcher = github_fetch) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("paths", nargs="*", help="repo-relative paths under db/migrations/")
    parser.add_argument("--all", action="store_true",
                        help="check every file under db/migrations/ and every CODE_COPIES file")
    parser.add_argument("--repo-root", default=str(Path(__file__).resolve().parent.parent))
    args = parser.parse_args(argv)
    root = Path(args.repo_root)
    paths = all_copies(root) if args.all else args.paths
    if not paths:
        print("no migration copies to check")
        return 0
    return run(paths, root, fetch)


if __name__ == "__main__":
    sys.exit(main())
