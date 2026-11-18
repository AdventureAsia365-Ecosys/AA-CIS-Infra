"""Stale-entry check of the X2 RLS catalogue allowlist against the live Dev dump (AA-1112). No network, no DB.

db/rls_catalogue_rules.py (byte copy of AA-CIS-App tests/integration/rls_catalogue_rules.py) lists every object that
may break an RLS catalogue rule, each with a one-line reason. An entry that matches nothing on Dev is stale: the table
was dropped, the grant revoked or the object fixed, and the entry would silently cover a new object of the same name
later. Until AA-1112 the nightly reference only reported stale entries; this check fails on them.

Input: the format-2 JSON of db/schema_dump.py (the latest successful DB Schema Dump run on main). Only Dev sees every
owner's objects: the CIS CI replay builds the CIS migrations only, so it checks the CIS-side entries alone
(AA-CIS-App tests/integration/test_rls_catalogue_guard.py).

Usage:
  python3 db/check_rls_allowlist.py schema.json

Exit: 0 no stale entry, 1 a stale entry (each printed with the file to edit), 2 the dump is unreadable.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))

import rls_catalogue_rules as rls  # noqa: E402

CANONICAL = "AA-CIS-App tests/integration/rls_catalogue_rules.py"
COPY = "db/rls_catalogue_rules.py"


def stale_entries(dump: dict, allowlist: Optional[dict] = None) -> list[tuple[str, str]]:
    """(rule, key) of every allowlist entry that matches no finding of the dump."""
    return list(rls.check(dump, allowlist).stale)


def main(argv: Optional[list[str]] = None, out=sys.stdout) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("dump", help="JSON written by db/schema_dump.py (format 2)")
    args = parser.parse_args(argv)
    try:
        dump = json.loads(Path(args.dump).read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as e:
        print(f"FAIL  dump {args.dump}: {e}", file=out)
        return 2
    if not isinstance(dump, dict) or dump.get("format") != 2:
        print(f"FAIL  dump {args.dump}: unsupported format {dump.get('format') if isinstance(dump, dict) else None!r} "
              "(expected 2)", file=out)
        return 2
    stale = stale_entries(dump)
    annotate = os.environ.get("GITHUB_ACTIONS") == "true"
    for rule, key in stale:
        msg = (f"RLS allowlist entry [{rule}] {key} matches nothing on Dev (stale). Remove it from ALLOWLIST[{rule!r}] "
               f"in {CANONICAL}, merge, then copy the file to AA-CIS-Infra {COPY}.")
        print(f"FAIL  {msg}", file=out)
        if annotate:
            print(f"::error file={COPY}::{msg}", file=out)
    n = sum(len(v) for v in rls.ALLOWLIST.values())
    print(f"{n} allowlist entry(ies), {len(stale)} stale", file=out)
    return 1 if stale else 0


if __name__ == "__main__":
    sys.exit(main())
