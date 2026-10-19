#!/usr/bin/env python3
"""Secrets register drift check (AA-878). Metadata only: it never reads a secret value.

Compares the secrets register (root repo docs/security/secrets-register.yaml) with inventories the
caller collected beforehand, all names only:

  --aws         JSON from `aws secretsmanager list-secrets --include-planned-deletion` (acc2).
                The compact form [{"n": name, "del": deleted_date|null}, ...] is accepted too.
  --gh          a directory of `gh secret list --json name,updatedAt` outputs, one file per scope:
                  <repo>.json        -> store github:<repo>
                  <repo>@<env>.json  -> store github:<repo>/<env>
                  org.json           -> store github:org
  --vercel      JSON {"<project>": [{"key": ..., "target": [...]}, ...] | ["KEY", ...]}.
  --lambda-env  JSON {"<function>": ["KEY", ...]} (`keys(Environment.Variables)` per function).

GitHub and Secrets Manager names must all be registered. For Vercel and Lambda env (which also
hold plain config) only names that look like secrets must be: SECRET|KEY|TOKEN|PASSWORD|... and
not *_ARN/*_NAME/*_HEADER/*_ID, and for Vercel not NEXT_PUBLIC_*.

Only stores with an inventory are checked; the others are listed as "not checked". It prints one
line per difference and `diff = N`, and exits 0 when N == 0, 1 on any difference, 2 on bad input.

Register row statuses:
  keep / pending-x1 / open-item  must exist in its store.
  planned                        must NOT exist yet (when it does, flip the row to keep).
  orphan-delete / pending-removal  must be gone, or (Secrets Manager) scheduled for deletion.
  deleted / removed              must be gone, or scheduled for deletion.

Stdlib + PyYAML. Usage:
  python tools/secrets/register_check.py --register ../../docs/security/secrets-register.yaml \
      --aws list-secrets.json [--gh gh-dir] [--vercel vercel.json] [--lambda-env lambda-env.json]
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Optional

STATUSES_PRESENT = {"keep", "pending-x1", "open-item"}
STATUSES_PLANNED = {"planned"}
STATUSES_GONE = {"orphan-delete", "pending-removal", "deleted", "removed"}
STATUSES = STATUSES_PRESENT | STATUSES_PLANNED | STATUSES_GONE

# Stores the checker can compare. Anything else (vendor:*, other accounts) is documentation only.
_CHECKABLE = re.compile(r"^(secretsmanager:acc2|github:[^/]+(/[^/]+)?|github:org|vercel:[^/]+|lambda-env:.+)$")

# A Lambda env key that looks like it carries a secret value (AA-878 scope 3).
_SECRETISH = re.compile(r"(SECRET|KEY|TOKEN|PASSWORD|PASSWD|CREDENTIAL)")
_SECRETISH_OK_SUFFIX = ("_ARN", "_NAME", "_HEADER", "_ID")


class InputError(Exception):
    """An inventory or the register cannot be read."""


@dataclass(frozen=True)
class Row:
    name: str
    store: str
    status: str


@dataclass
class Inventory:
    """Names present per store; `scheduled` holds Secrets Manager names pending deletion."""

    present: dict[str, set[str]]
    scheduled: dict[str, set[str]]

    def checked(self, store: str) -> bool:
        return store in self.present


def looks_like_secret_value(key: str) -> bool:
    return bool(_SECRETISH.search(key)) and not key.endswith(_SECRETISH_OK_SUFFIX)


# --- loading -------------------------------------------------------------------------------

def _read_json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise InputError(f"cannot read {path}: {type(exc).__name__}") from None


def load_register(path: Path) -> list[Row]:
    try:
        import yaml  # PyYAML
    except ImportError:  # pragma: no cover - CI installs it
        raise InputError("PyYAML is required (pip install pyyaml)") from None
    try:
        doc = yaml.safe_load(path.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as exc:
        raise InputError(f"cannot read register {path}: {type(exc).__name__}") from None
    entries = doc.get("secrets") if isinstance(doc, dict) else None
    if not isinstance(entries, list):
        raise InputError("register has no 'secrets' list")
    rows: list[Row] = []
    seen: set[tuple[str, str]] = set()
    for i, e in enumerate(entries):
        if not isinstance(e, dict) or not e.get("name") or not e.get("store") or not e.get("status"):
            raise InputError(f"register row {i} needs name, store and status")
        row = Row(str(e["name"]), str(e["store"]), str(e["status"]))
        if row.status not in STATUSES:
            raise InputError(f"register row {i} ({row.name}): unknown status {row.status!r}")
        if (row.store, row.name) in seen:
            raise InputError(f"register row {i}: duplicate {row.store} {row.name}")
        seen.add((row.store, row.name))
        rows.append(row)
    return rows


def _aws(data, inv: Inventory) -> None:
    items = data.get("SecretList") if isinstance(data, dict) else data
    if not isinstance(items, list):
        raise InputError("--aws: expected list-secrets JSON")
    store = "secretsmanager:acc2"
    inv.present.setdefault(store, set())
    inv.scheduled.setdefault(store, set())
    for s in items:
        name = s.get("Name") or s.get("n")
        if not name:
            raise InputError("--aws: entry without a name")
        if s.get("DeletedDate") or s.get("del"):
            inv.scheduled[store].add(name)
        else:
            inv.present[store].add(name)


def _gh(directory: Path, inv: Inventory) -> None:
    if not directory.is_dir():
        raise InputError(f"--gh: {directory} is not a directory")
    for f in sorted(directory.glob("*.json")):
        stem = f.stem
        if stem == "org":
            store = "github:org"
        elif "@" in stem:
            repo, env = stem.split("@", 1)
            store = f"github:{repo}/{env}"
        else:
            store = f"github:{stem}"
        data = _read_json(f)
        if not isinstance(data, list):
            raise InputError(f"--gh: {f.name} is not a gh secret list JSON array")
        inv.present.setdefault(store, set()).update(str(s["name"]) for s in data)


def _vercel(data, inv: Inventory) -> None:
    if not isinstance(data, dict):
        raise InputError("--vercel: expected {project: [...]}")
    for project, envs in data.items():
        names = {e if isinstance(e, str) else e.get("key") for e in (envs or [])}
        inv.present.setdefault(f"vercel:{project}", set()).update(n for n in names if n)


def _lambda(data, inv: Inventory) -> None:
    if not isinstance(data, dict):
        raise InputError("--lambda-env: expected {function: [keys]}")
    for fn, keys in data.items():
        if not isinstance(keys, list):
            raise InputError(f"--lambda-env: {fn} keys are not a list")
        inv.present.setdefault(f"lambda-env:{fn}", set()).update(str(k) for k in keys)


def load_inventory(aws: Optional[Path], gh: Optional[Path], vercel: Optional[Path],
                   lambda_env: Optional[Path]) -> Inventory:
    inv = Inventory(present={}, scheduled={})
    if aws:
        _aws(_read_json(aws), inv)
    if gh:
        _gh(gh, inv)
    if vercel:
        _vercel(_read_json(vercel), inv)
    if lambda_env:
        _lambda(_read_json(lambda_env), inv)
    return inv


# --- comparison ----------------------------------------------------------------------------

def compare(rows: Iterable[Row], inv: Inventory) -> tuple[list[str], list[str]]:
    """Return (difference lines, stores in the register that were not checked)."""
    rows = list(rows)
    diffs: list[str] = []
    not_checked: set[str] = set()
    registered: dict[str, set[str]] = {}

    for r in rows:
        registered.setdefault(r.store, set()).add(r.name)
        if not _CHECKABLE.match(r.store) or not inv.checked(r.store):
            not_checked.add(r.store)
            continue
        present = r.name in inv.present[r.store]
        scheduled = r.name in inv.scheduled.get(r.store, set())
        if r.status in STATUSES_PRESENT:
            if scheduled:
                diffs.append(f"SCHEDULED-FOR-DELETION {r.store} {r.name} (register: {r.status})")
            elif not present:
                diffs.append(f"MISSING {r.store} {r.name} (register: {r.status})")
        elif r.status in STATUSES_PLANNED:
            if present:
                diffs.append(f"PLANNED-NOW-PRESENT {r.store} {r.name} (set status: keep)")
        elif present:
            diffs.append(f"STILL-PRESENT {r.store} {r.name} (register: {r.status})")

    for store, names in inv.present.items():
        known = registered.get(store, set())
        candidates = names | inv.scheduled.get(store, set())
        if store.startswith("lambda-env:"):
            # Only keys that look like secret values must be in the register.
            candidates = {k for k in candidates if looks_like_secret_value(k)}
            for k in sorted(candidates - known):
                diffs.append(f"LAMBDA-ENV-SECRET {store} {k} (plaintext env key looks like a secret)")
            continue
        if store.startswith("vercel:"):
            # Vercel holds config too: only secret-looking names must be registered, and
            # NEXT_PUBLIC_* are public by definition (baked into the browser bundle).
            candidates = {k for k in candidates
                          if looks_like_secret_value(k) and not k.startswith("NEXT_PUBLIC_")}
        for n in sorted(candidates - known):
            diffs.append(f"UNREGISTERED {store} {n}")

    return sorted(diffs), sorted(not_checked)


def main(argv: Optional[list[str]] = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    p.add_argument("--register", required=True, type=Path)
    p.add_argument("--aws", type=Path)
    p.add_argument("--gh", type=Path)
    p.add_argument("--vercel", type=Path)
    p.add_argument("--lambda-env", dest="lambda_env", type=Path)
    a = p.parse_args(argv)
    if not any((a.aws, a.gh, a.vercel, a.lambda_env)):
        p.error("give at least one inventory (--aws, --gh, --vercel, --lambda-env)")
    try:
        rows = load_register(a.register)
        inv = load_inventory(a.aws, a.gh, a.vercel, a.lambda_env)
    except InputError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    diffs, not_checked = compare(rows, inv)
    for line in diffs:
        print(line)
    print(f"checked stores: {', '.join(sorted(inv.present)) or '-'}")
    print(f"not checked (no inventory or documentation only): {len(not_checked)} stores")
    print(f"diff = {len(diffs)}")
    return 1 if diffs else 0


if __name__ == "__main__":
    sys.exit(main())
