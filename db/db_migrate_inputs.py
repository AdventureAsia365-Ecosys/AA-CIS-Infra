#!/usr/bin/env python3
"""DB Migrate input check before anything else runs (AA-1119, S282 audit: DB Migrate dispatched without checking its
input first).

The `inputs` job of .github/workflows/db-migrate.yml runs this first: no GitHub environment, no AWS credentials, no
secret. Every reason is printed at once (one `::error::` line each) and the run fails there, before the `target` job,
the `migrate` job's environment and the OIDC role. The `migrate` job's own "Unused inputs" and "Validate input" steps
stay as they are (they also compute the version key and run the lint); this check is the fail-fast front of them, and
its lists come from db/owners.yaml instead of literals:

  * the run comes from main (the jobs below are `if: github.ref == 'refs/heads/main'`: from another ref they used to
    skip, and the run looked green);
  * mode is one of check, apply, set-password, run-script, and each mode gets only its own input;
  * the environment is in db/owners.yaml `environments`;
  * check / apply: `<owner>/<NNN>_<name>.sql` with an owner of db/owners.yaml `owners`, and the file is a regular file
    under db/migrations/ in this checkout (main);
  * set-password: the role is in db/owners.yaml `password_roles`;
  * run-script: `db/scripts/<name>.py`, a regular file (not a link) inside db/scripts/ in this checkout;
  * override_busy_jobs: not blank, one line, at most 200 characters (the same rule as "Validate input").

Inputs come from the environment (never from the command line, so no input is ever parsed by a shell):
GITHUB_REF, MODE, ENVIRONMENT, MIGRATION_INPUT, ROLE_INPUT, SCRIPT_INPUT, OVERRIDE_BUSY_JOBS. Standard library only:
db/owners.yaml is read by a small reader of the three keys it needs (db/tests/test_aa1119_db_migrate_inputs.py checks
it against PyYAML). Run: python3 db/db_migrate_inputs.py [--root DIR]. Exit 0 = valid, 1 = refused.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from collections.abc import Mapping
from pathlib import Path

MODES = ("check", "apply", "set-password", "run-script")
MAIN_REF = "refs/heads/main"
# The same one-line limit the "Validate input" step applies (a reason written into the run summary and the task log).
OVERRIDE_MAX_CHARS = 200  # technical-constant: input format of the existing step, mirrored
SCRIPT_RE = re.compile(r"^db/scripts/[a-z0-9_]+\.py$")


def _top_level(text: str, key: str) -> str | None:
    """The raw value of a top-level `key: value` line (comments stripped), or None."""
    for line in text.splitlines():
        m = re.match(rf"^{re.escape(key)}:(.*)$", line)
        if m:
            return m.group(1).split("#", 1)[0].strip()
    return None


def read_registry(text: str) -> dict:
    """environments, password_roles (names) and owners (dir names) of db/owners.yaml."""
    envs = _top_level(text, "environments") or ""
    m = re.fullmatch(r"\[(.*)\]", envs)
    environments = [e.strip() for e in m.group(1).split(",") if e.strip()] if m else []
    roles_raw = _top_level(text, "password_roles") or ""
    m = re.fullmatch(r"\{(.*)\}", roles_raw)
    password_roles = [p.split(":", 1)[0].strip() for p in m.group(1).split(",") if p.strip()] if m else []
    owners: list[str] = []
    inside = False
    for line in text.splitlines():
        if re.match(r"^owners:\s*(#.*)?$", line):
            inside = True
            continue
        if inside:
            if line and not line.startswith((" ", "#")):
                break  # the next top-level key
            m = re.match(r"^  ([a-z][a-z0-9_]*):\s*(#.*)?$", line)
            if m:
                owners.append(m.group(1))
    return {"environments": environments, "password_roles": password_roles, "owners": owners}


def _regular_file_inside(root: Path, rel: str, base: str) -> str | None:
    """None when `rel` (relative to root) is a regular, non-link file inside root/base; else why not."""
    path = root / rel
    if path.is_symlink():
        return f"{rel} is a symbolic link"
    if not path.is_file():
        return f"{rel} not found on main"
    try:
        path.resolve().relative_to((root / base).resolve())
    except ValueError:
        return f"{rel} is outside {base}/"
    return None


USED = {"check": {"migration"}, "apply": {"migration"}, "set-password": {"role"}, "run-script": {"script"}}


def _input_errors(mode: str, given: Mapping[str, str], override: str) -> list[str]:
    """Each mode takes only its own input; the override reason is one non-blank line."""
    errors = []
    used = USED[mode]
    extra = sorted(name for name, value in given.items() if value and name not in used)
    if extra:
        errors.append(f"mode {mode} takes only {', '.join(sorted(used))}; leave {', '.join(extra)} empty")
    if override and mode == "set-password":
        errors.append("mode set-password takes no override_busy_jobs")
    reason = override.strip()
    if override and not reason:
        errors.append("override_busy_jobs is blank: leave it empty, or give a reason")
    elif len(reason) > OVERRIDE_MAX_CHARS or "\n" in reason:
        errors.append(f"override_busy_jobs must be one line of at most {OVERRIDE_MAX_CHARS} characters")
    return errors


def _migration_errors(mode: str, migration: str, registry: dict, root: Path) -> list[str]:
    owners = "|".join(re.escape(o) for o in registry["owners"])
    if not migration:
        return [f"mode {mode} needs the migration input, e.g. cis/215_name.sql"]
    if not re.fullmatch(rf"({owners})/[0-9]{{3}}_[a-z0-9_]+\.sql", migration):
        return [
            f"migration must look like <owner>/215_name.sql with an owner of db/owners.yaml "
            f"({', '.join(registry['owners'])})"
        ]
    why = _regular_file_inside(root, f"db/migrations/{migration}", "db/migrations")
    return [why] if why else []


def _script_errors(script: str, root: Path) -> list[str]:
    if not script:
        return ["mode run-script needs the script input, e.g. db/scripts/session_info.py"]
    if not SCRIPT_RE.fullmatch(script):
        return ["script must look like db/scripts/name.py (lower case, digits, underscores)"]
    why = _regular_file_inside(root, script, "db/scripts")
    return [why] if why else []


def _target_errors(mode: str, given: Mapping[str, str], registry: dict, root: Path) -> list[str]:
    """The mode's own input names a migration file, a password role or a db/scripts/ script on main."""
    if mode in ("check", "apply"):
        return _migration_errors(mode, given["migration"], registry, root)
    if mode == "set-password":
        if given["role"] in registry["password_roles"]:
            return []
        return [f"role must be one of db/owners.yaml password_roles ({', '.join(registry['password_roles'])})"]
    return _script_errors(given["script"], root)


def check(env: Mapping[str, str], root: Path) -> list[str]:
    """Every reason the dispatch is refused (empty = valid)."""
    errors: list[str] = []
    ref = env.get("GITHUB_REF", "")
    if ref != MAIN_REF:
        errors.append(f"DB Migrate runs from main only (this run is on {ref or 'no ref'}): dispatch it on main")
    registry = read_registry((root / "db" / "owners.yaml").read_text(encoding="utf-8"))
    environment = env.get("ENVIRONMENT", "")
    if environment not in registry["environments"]:
        errors.append(
            f"environment {environment or '(empty)'} is not in db/owners.yaml environments "
            f"({', '.join(registry['environments'])})"
        )
    mode = env.get("MODE", "")
    if mode not in MODES:
        return [*errors, f"mode must be one of {', '.join(MODES)}"]
    given = {
        "migration": env.get("MIGRATION_INPUT", ""),
        "role": env.get("ROLE_INPUT", ""),
        "script": env.get("SCRIPT_INPUT", ""),
    }
    errors += _input_errors(mode, given, env.get("OVERRIDE_BUSY_JOBS", ""))
    return errors + _target_errors(mode, given, registry, root)


def main(argv: list[str] | None = None, env: Mapping[str, str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--root", default=str(Path(__file__).resolve().parent.parent))
    a = p.parse_args(argv)
    errors = check(os.environ if env is None else env, Path(a.root))
    for e in errors:
        print(f"::error title=DB Migrate input::{e}")
    if not errors:
        print("DB Migrate inputs are valid")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
