"""AA-1119: DB Migrate checks its inputs first (db/db_migrate_inputs.py, job `inputs` of db-migrate.yml).

Offline, standard library (PyYAML only for the registry reader cross-check, skipped without it). Each case builds a
throwaway tree with db/owners.yaml copied from the repo and the files it needs.
Run: python3 -m unittest db.tests.test_aa1119_db_migrate_inputs -v
"""

from __future__ import annotations

import io
import os
import shutil
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "db"))

import db_migrate_inputs as dmi  # noqa: E402

REGISTRY_TEXT = (ROOT / "db" / "owners.yaml").read_text(encoding="utf-8")
WORKFLOW_TEXT = (ROOT / ".github" / "workflows" / "db-migrate.yml").read_text(encoding="utf-8")
MAIN = "refs/heads/main"


class Tree:
    def __init__(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        (self.root / "db").mkdir()
        shutil.copy(ROOT / "db" / "owners.yaml", self.root / "db" / "owners.yaml")

    def add(self, rel: str, text: str = "-- probe\n") -> Path:
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    def close(self) -> None:
        self._tmp.cleanup()


def env(**kw: str) -> dict:
    base = {
        "GITHUB_REF": MAIN,
        "MODE": "check",
        "ENVIRONMENT": "dev",
        "MIGRATION_INPUT": "",
        "ROLE_INPUT": "",
        "SCRIPT_INPUT": "",
        "OVERRIDE_BUSY_JOBS": "",
    }
    base.update(kw)
    return base


class RegistryReaderTest(unittest.TestCase):
    def test_reads_the_three_keys_like_pyyaml(self):
        try:
            import yaml
        except ImportError:
            self.skipTest("PyYAML is not installed")
        reg = yaml.safe_load(REGISTRY_TEXT)
        got = dmi.read_registry(REGISTRY_TEXT)
        self.assertEqual(got["environments"], reg["environments"])
        self.assertEqual(got["password_roles"], list(reg["password_roles"]))
        self.assertEqual(got["owners"], list(reg["owners"]))

    def test_owners_block_ends_at_the_next_top_level_key(self):
        text = (
            "environments: [dev, prod]  # c\nowners:\n  cis:\n    repo: A\n  roles:\n    native: true\nnext: 1\n"
            "  stray:\npassword_roles: {a_role: s/1, b_role: s/2}\n"
        )
        got = dmi.read_registry(text)
        self.assertEqual(
            got, {"environments": ["dev", "prod"], "password_roles": ["a_role", "b_role"], "owners": ["cis", "roles"]}
        )


class CheckTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tree = Tree()
        self.addCleanup(self.tree.close)
        self.owner = dmi.read_registry(REGISTRY_TEXT)["owners"][0]
        self.migration = f"{self.owner}/999_probe_file.sql"
        self.tree.add(f"db/migrations/{self.migration}")
        self.tree.add("db/scripts/probe_script.py", "async def main(conn):\n    return None\n")

    def errors(self, **kw: str) -> list[str]:
        return dmi.check(env(**kw), self.tree.root)

    def test_valid_dispatches(self):
        self.assertEqual(self.errors(MIGRATION_INPUT=self.migration), [])
        self.assertEqual(self.errors(MODE="apply", MIGRATION_INPUT=self.migration, OVERRIDE_BUSY_JOBS="reason"), [])
        role = dmi.read_registry(REGISTRY_TEXT)["password_roles"][0]
        self.assertEqual(self.errors(MODE="set-password", ROLE_INPUT=role), [])
        self.assertEqual(self.errors(MODE="run-script", SCRIPT_INPUT="db/scripts/probe_script.py"), [])

    def test_every_owner_of_the_registry_is_accepted(self):
        for owner in dmi.read_registry(REGISTRY_TEXT)["owners"]:
            with self.subTest(owner=owner):
                self.tree.add(f"db/migrations/{owner}/998_probe_file.sql")
                self.assertEqual(self.errors(MIGRATION_INPUT=f"{owner}/998_probe_file.sql"), [])

    def test_other_ref_is_refused(self):
        errs = self.errors(GITHUB_REF="refs/heads/feature-x", MIGRATION_INPUT=self.migration)
        self.assertEqual(len(errs), 1)
        self.assertIn("main only", errs[0])

    def test_refusals(self):
        cases = {
            "unknown mode": ({"MODE": "drop"}, "mode must be one of"),
            "unknown environment": (
                {"ENVIRONMENT": "prod", "MIGRATION_INPUT": self.migration},
                "not in db/owners.yaml",
            ),
            "no migration": ({"MODE": "apply"}, "needs the migration input"),
            "unknown owner": ({"MIGRATION_INPUT": "nobody/999_probe_file.sql"}, "owner of db/owners.yaml"),
            "bad name": ({"MIGRATION_INPUT": f"{self.owner}/99_x.sql"}, "must look like"),
            "traversal": ({"MIGRATION_INPUT": f"{self.owner}/../999_x.sql"}, "must look like"),
            "missing file": ({"MIGRATION_INPUT": f"{self.owner}/997_absent.sql"}, "not found on main"),
            "unused role": ({"MIGRATION_INPUT": self.migration, "ROLE_INPUT": "cis_app"}, "takes only migration"),
            "unused script": (
                {"MODE": "set-password", "ROLE_INPUT": "cis_app", "SCRIPT_INPUT": "db/scripts/x.py"},
                "takes only role",
            ),
            "unknown role": ({"MODE": "set-password", "ROLE_INPUT": "postgres"}, "password_roles"),
            "override on set-password": (
                {"MODE": "set-password", "ROLE_INPUT": "cis_app", "OVERRIDE_BUSY_JOBS": "why"},
                "no override_busy_jobs",
            ),
            "blank override": (
                {"MODE": "apply", "MIGRATION_INPUT": self.migration, "OVERRIDE_BUSY_JOBS": "   "},
                "blank",
            ),
            "long override": (
                {
                    "MODE": "apply",
                    "MIGRATION_INPUT": self.migration,
                    "OVERRIDE_BUSY_JOBS": "x" * (dmi.OVERRIDE_MAX_CHARS + 1),
                },
                "one line",
            ),
            "two-line override": (
                {"MODE": "apply", "MIGRATION_INPUT": self.migration, "OVERRIDE_BUSY_JOBS": "a\nb"},
                "one line",
            ),
            "no script": ({"MODE": "run-script"}, "needs the script input"),
            "script outside db/scripts": (
                {"MODE": "run-script", "SCRIPT_INPUT": "db/run_migration.py"},
                "must look like db/scripts",
            ),
            "missing script": ({"MODE": "run-script", "SCRIPT_INPUT": "db/scripts/absent.py"}, "not found on main"),
        }
        for name, (kw, needle) in cases.items():
            with self.subTest(name):
                errs = self.errors(**kw)
                self.assertTrue(any(needle in e for e in errs), errs)

    @unittest.skipUnless(hasattr(os, "symlink"), "needs symlinks")
    def test_linked_script_is_refused(self):
        outside = self.tree.add("elsewhere/evil.py", "async def main(conn):\n    return None\n")
        os.symlink(outside, self.tree.root / "db" / "scripts" / "linked.py")
        errs = self.errors(MODE="run-script", SCRIPT_INPUT="db/scripts/linked.py")
        self.assertTrue(any("symbolic link" in e for e in errs), errs)

    def test_every_reason_at_once(self):
        errs = self.errors(GITHUB_REF="refs/heads/x", ENVIRONMENT="qa", MODE="apply", ROLE_INPUT="cis_app")
        self.assertEqual(len(errs), 4, errs)

    def test_main_prints_error_lines_and_exit_code(self):
        buf = io.StringIO()
        with redirect_stdout(buf):
            code = dmi.main(["--root", str(self.tree.root)], env(MODE="apply"))
        self.assertEqual(code, 1)
        self.assertIn("::error title=DB Migrate input::mode apply needs the migration input", buf.getvalue())
        buf = io.StringIO()
        with redirect_stdout(buf):
            code = dmi.main(["--root", str(self.tree.root)], env(MIGRATION_INPUT=self.migration))
        self.assertEqual(code, 0)


class WorkflowTest(unittest.TestCase):
    """The `inputs` job runs first, with no environment, no AWS and no secret; `target` (and so `migrate`) needs it."""

    def job(self, name: str) -> str:
        start = WORKFLOW_TEXT.index(f"\n  {name}:\n")
        rest = WORKFLOW_TEXT[start + 1 :]
        nxt = [i for i in (rest.find("\n  target:\n"), rest.find("\n  migrate:\n")) if i > 0]
        return rest[: min(nxt)] if nxt else rest

    def test_inputs_job(self):
        job = self.job("inputs")
        self.assertIn("run: python3 db/db_migrate_inputs.py", job)
        for forbidden in ("environment:", "id-token", "secrets.", "configure-aws-credentials", "if:"):
            self.assertNotIn(forbidden, job)
        for var in ("MODE", "ENVIRONMENT", "MIGRATION_INPUT", "ROLE_INPUT", "SCRIPT_INPUT", "OVERRIDE_BUSY_JOBS"):
            self.assertIn(f"          {var}: ${{{{ inputs.", job)
        target = self.job("target")
        self.assertIn("    needs: inputs\n", target)
        self.assertIn("if: github.ref == 'refs/heads/main'", target)
        self.assertLess(WORKFLOW_TEXT.index("\n  inputs:\n"), WORKFLOW_TEXT.index("\n  target:\n"))
        self.assertIn("    needs: target\n", WORKFLOW_TEXT[WORKFLOW_TEXT.index("\n  migrate:\n") :])

    def test_modes_match_the_workflow_choices(self):
        try:
            import yaml
        except ImportError:
            self.skipTest("PyYAML is not installed")
        wf = yaml.safe_load(WORKFLOW_TEXT)
        on = wf.get("on", wf.get(True))
        self.assertEqual(tuple(on["workflow_dispatch"]["inputs"]["mode"]["options"]), dmi.MODES)


if __name__ == "__main__":
    unittest.main()
