"""The new-owner role bootstrap template (ADR 0008 playbook step 3, AA-826): db/templates/new_owner_roles.sql.tmpl
rendered by db/templates/render_new_owner_roles.py passes the same static rules as every roles/ file
(test_roles_files.py) and the DB Migrate lint, and has the shape the playbook needs. Rendering refuses bad input.

Run: python3 -m unittest discover -s db/tests -v
"""
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "db"))
sys.path.insert(0, str(ROOT / "db" / "templates"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import render_new_owner_roles as tmpl  # noqa: E402
import run_migration as rm  # noqa: E402
from test_roles_files import code_view, connection_limits, memberships, membership_violations  # noqa: E402

ARGS = dict(number="099", owner="crm", owner_role="crm_owner", runtime_role="crm_app", schema="crm",
            key_prefix="cr-", conn_limit=15, issue="AA-826")
SQL = tmpl.render(**ARGS)
VIEW = code_view(SQL)


class RenderedFileTest(unittest.TestCase):
    def test_no_placeholder_left(self):
        self.assertNotIn("{{", SQL)

    def test_db_migrate_lint_passes(self):
        errors, warnings = rm.lint(SQL, rm.parse_directives(SQL), "db/migrations/roles/099_crm_roles.sql")
        self.assertEqual((errors, warnings), ([], []))

    def test_registers_its_rl_key(self):
        sys.path.insert(0, str(ROOT / "db"))
        import check_migration_copies as guard
        self.assertEqual(guard.check_registration("roles", "099", SQL), [])

    def test_roles_file_rules(self):
        self.assertNotRegex(VIEW, r"\bPASSWORD\b")
        self.assertNotRegex(VIEW, r"\b(SUPERUSER|BYPASSRLS|REPLICATION)\b")
        self.assertEqual(membership_violations(VIEW), [])

    def test_shape(self):
        self.assertIn("CREATE ROLE CRM_OWNER NOLOGIN", VIEW)
        self.assertRegex(VIEW, r"CREATE ROLE CRM_APP LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS "
                               r"CONNECTION LIMIT 15")
        self.assertEqual(connection_limits(VIEW), {"crm_app": 15})
        self.assertIn("CREATE SCHEMA IF NOT EXISTS CRM AUTHORIZATION CRM_OWNER", VIEW)
        self.assertIn("IF session_user <> 'aa_cis_admin' THEN", SQL)      # master-only guard
        # Memberships: the owner role to the master and the DB Migrate login, nothing else, nothing to the runtime.
        self.assertEqual(sorted((tuple(r), tuple(t)) for r, t in memberships(VIEW)),
                         [(("CRM_OWNER",), ("AA_CIS_ADMIN",)), (("CRM_OWNER",), ("DB_MIGRATOR",))])
        self.assertEqual(SQL.count("BEGIN;"), 1)
        self.assertTrue(SQL.rstrip().endswith("COMMIT;"))

    def test_no_object_grant_or_default_acl(self):
        # Objects, grants and default privileges belong to the owner's own migrations.
        self.assertNotRegex(VIEW, r"\bGRANT\b[^;]*\bON\b")
        self.assertNotIn("DEFAULT PRIVILEGES", VIEW)


class RenderRefusesTest(unittest.TestCase):
    def test_bad_input(self):
        bad = [dict(number="99"), dict(owner_role="cis_owner"), dict(runtime_role="crm_owner"),
               dict(schema="shared"), dict(schema="Crm"), dict(key_prefix="cr"), dict(conn_limit=0),
               dict(conn_limit=500), dict(issue="826"), dict(runtime_role="aa_app_user")]
        for override in bad:
            with self.subTest(**override), self.assertRaises(ValueError):
                tmpl.render(**{**ARGS, **override})

    def test_cli(self):
        import io
        from unittest import mock
        out = io.StringIO()
        with mock.patch("sys.stdout", out):
            code = tmpl.main(["--number", "099", "--owner", "crm", "--owner-role", "crm_owner", "--runtime-role",
                              "crm_app", "--schema", "crm", "--key-prefix", "cr-", "--conn-limit", "15",
                              "--issue", "AA-826"])
        self.assertEqual(code, 0)
        self.assertEqual(out.getvalue(), SQL)
        self.assertIsNotNone(re.search(r"VALUES \('rl-099'", out.getvalue()))


if __name__ == "__main__":
    unittest.main()
