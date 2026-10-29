#!/usr/bin/env python3
"""Does a pull request touch the paths the Migration Copy Guard checks? (AA-993 I1)

The guard's jobs are required checks of the ruleset on main (tools/github/infra-main-ruleset.json). A required check
whose workflow never starts blocks the PR, so migration-copy-guard.yml runs on every PR and its `scope` job calls
this script: when no changed path matches, the guard, lint and retention-rows jobs are skipped (a skipped job counts
as passed). PATHS is the list that used to be the workflow's `pull_request.paths` filter; scripts/pre-push.sh keeps
the same list for its local selection (db/tests/test_migration_guard_scope.py checks that both agree).

Glob rules are GitHub's filter rules: `*` matches within one path segment, `**` matches across segments.

Usage:
  migration_guard_scope.py < changed-files.txt        prints relevant=true|false (GITHUB_OUTPUT line format)
"""
from __future__ import annotations

import re
import sys

PATHS: tuple[str, ...] = (
    "db/migrations/**",
    "db/check_migration_copies.py",
    "db/rls_catalogue_rules.py",
    "db/replay_migrations.py",
    "db/schema_drift.py",
    "db/schema_drift_decisions.json",
    "db/replay_baseline/**",
    "db/gen_replay_baseline.py",
    "db/gen_schema_reference.py",
    "db/schema_dump_automerge.py",
    "db/gen_erd.py",
    "tools/docs/aws_mask.py",
    "db/check_erd_drift.py",
    "db/schema_dump.py",
    "db/check_migration_files.py",
    "db/check_migration_ownership.py",
    "db/check_retention_rows.py",
    "db/run_migration.py",
    "db/expand_check.py",
    "db/migration_guard_scope.py",
    "db/tests/**",
    "db/owners.yaml",
    "db/isolation_probe.py",
    "db/tour_liveness_gate.py",
    "db/freshness_gate.py",
    "db/scripts/**",
    "db/templates/**",
    ".github/scripts/**",
    ".github/workflows/db-isolation-probe.yml",
    ".github/workflows/db-tour-liveness-gate.yml",
    ".github/workflows/db-freshness-probe.yml",
    ".github/workflows/db-migrate.yml",
    ".github/workflows/db-schema-dump.yml",
    ".github/workflows/migration-copy-guard.yml",
    # AA-993 M3: the auto-apply's runner side, the copy sync and the ruleset its merge check reads.
    "db/apply_pending.py",
    "db/migration_sync.py",
    ".github/workflows/migration-apply.yml",
    ".github/workflows/migration-sync.yml",
    "tools/github/infra-main-ruleset.json",
)


def _glob_to_re(pattern: str) -> re.Pattern[str]:
    out = []
    i = 0
    while i < len(pattern):
        if pattern.startswith("**", i):
            out.append(".*")
            i += 2
        elif pattern[i] == "*":
            out.append("[^/]*")
            i += 1
        elif pattern[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(pattern[i]))
            i += 1
    return re.compile("".join(out) + r"\Z")


_COMPILED = tuple(_glob_to_re(p) for p in PATHS)


def matches(path: str) -> bool:
    return any(rx.match(path) for rx in _COMPILED)


def relevant(paths: list[str]) -> bool:
    return any(matches(p) for p in paths if p)


def main() -> int:
    changed = [line.strip() for line in sys.stdin if line.strip()]
    print(f"relevant={'true' if relevant(changed) else 'false'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
