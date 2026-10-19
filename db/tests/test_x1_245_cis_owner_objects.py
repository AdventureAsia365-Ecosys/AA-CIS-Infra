"""X1 S21 (AA-860): db/scripts/x1_245_cis_owner_objects.py — the read-only list of what CIS 245 moves and refuses.

No database, no asyncpg: a fake connection answers the script's SQL. The script itself was run against a local
PostgreSQL 16 in the Dev shape before 245 (the AA-CIS-App test_aa860_migration_245 fixture up to 244): its `move`
lines were identical, in order, to the NOTICE lines of the 245 apply that followed (128 objects there).
Run: python3 -m unittest discover -s db/tests -v
"""
import asyncio
import contextlib
import importlib.util
import io
import re
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import run_migration as rm  # noqa: E402

ROOT = HERE.parent.parent
PATH = "db/scripts/x1_245_cis_owner_objects.py"
COPY_245 = ROOT / "db/migrations/cis/245_x1_cis_owner.sql"
_spec = importlib.util.spec_from_file_location("x1_245_cis_owner_objects", ROOT / PATH)
script = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(script)


def _norm(sql: str) -> str:
    return " ".join(sql.split())


class FakeConn:
    """Answers each of the script's queries by identity; every list defaults to empty (a clean Dev)."""

    def __init__(self, **over):
        self.answers = {
            "login": {"login": "aa_cis_admin", "in_owner": True, "in_app": True, "v244": True, "v245": False},
            "owner": {"nologin": True, "plain": True, "member_of": None, "create_on_db": True,
                      "members": "aa_cis_admin,db_migrator"},
            "move": [{"kind": "TABLE", "name": "shared.job"}, {"kind": "VIEW", "name": "shared.v_tour_photos"},
                     {"kind": "FUNCTION", "name": "geo.name_norm(p text)"}],
            "refuse": [], "secdef": [],
            "rls": [{"name": t, "force": True} for t in script.FORCE_EXPECTED]
                   + [{"name": "acp_shared.facts", "force": False}],
            "policies": [], "default_acl": [], "views": [], "lock": 108, "schemas": [],
        }
        self.answers.update(over)

    def _key(self, sql):
        return {script.LOGIN_SQL: "login", script.OWNER_ROLE_SQL: "owner", script.MOVE_SQL: "move",
                script.REFUSE_OWNER_SQL: "refuse", script.SECDEF_SQL: "secdef", script.RLS_SQL: "rls",
                script.OWNER_POLICY_SQL: "policies", script.DEFAULT_ACL_SQL: "default_acl",
                script.VIEWS_SQL: "views", script.LOCK_SQL: "lock", script.SCHEMAS_SQL: "schemas"}[sql]

    async def fetchrow(self, sql, *args):
        return self.answers[self._key(sql)]

    async def fetch(self, sql, *args):
        return self.answers[self._key(sql)]

    async def fetchval(self, sql, *args):
        return self.answers[self._key(sql)]


def run(conn) -> list:
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        asyncio.run(script.main(conn))
    return out.getvalue().splitlines()


class ShapeTests(unittest.TestCase):
    def test_runner_accepts_it_as_a_read_only_script(self):
        source = (ROOT / PATH).read_text()
        self.assertEqual(rm.script_errors(source, PATH), [])
        self.assertTrue(rm.script_is_read_only(source))

    def test_move_query_is_245_step_4(self):
        """The script prints what 245 will move only while MOVE_SQL is the migration's own step-4 query."""
        if not COPY_245.exists():
            self.skipTest("db/migrations/cis/245_x1_cis_owner.sql not copied yet (X1 S21 Infra copy PR)")
        self.assertIn(_norm(script.MOVE_SQL), _norm(COPY_245.read_text()))

    def test_move_query_names_the_master_and_the_11_runtime_schemas(self):
        q = _norm(script.MOVE_SQL)
        self.assertIn("r.rolname = 'aa_cis_admin'", q)
        for s in script.RUNTIME_SCHEMAS:
            self.assertIn(f"'{s}'", q)
        self.assertNotIn("'catalog'", q)                       # 245 moves only schema catalog, not its views


class OutputTests(unittest.TestCase):
    def test_clean_dev_is_ok(self):
        lines = run(FakeConn())
        self.assertIn("SCRIPT move table shared.job", lines)
        self.assertIn("SCRIPT move_total 3 function=1 table=1 view=1", lines)
        self.assertEqual(lines[-1], "SCRIPT summary move=3 refuse=0 ok=t")

    def test_refusals_are_named(self):
        conn = FakeConn(
            owner={"nologin": True, "plain": True, "member_of": None, "create_on_db": False,
                   "members": "aa_cis_admin,booking"},
            refuse=[{"kind": "relation S", "name": "acp_shared.x", "owner": "tripplanner", "extension_member": False,
                     "reason": "third_owner"},
                    {"kind": "routine", "name": "shared.vec_fn", "owner": "aa_cis_admin", "extension_member": True,
                     "reason": "kind_not_moved"}],
            secdef=[{"name": "shared.f", "owner": "aa_cis_admin"}],
            rls=[{"name": "acp_shared.new_force", "force": True}],
            default_acl=[{"role": "aa_cis_admin", "schema": "shared", "type": "r", "grantee": "aa_app_user",
                          "privileges": "SELECT"}])
        lines = run(conn)
        self.assertIn("SCRIPT refuse third_owner relation S acp_shared.x (tripplanner)", lines)
        self.assertIn("SCRIPT extension_member routine shared.vec_fn", lines)   # left with the master, not refused
        self.assertIn("SCRIPT refuse security_definer routine shared.f (aa_cis_admin)", lines)
        summary = lines[-1]
        self.assertTrue(summary.startswith("SCRIPT summary move=3 refuse=") and " ok=f " in summary + " ")
        for reason in ("default_acl", "force_set", "guard0_cis_owner_no_create_on_db",
                       "guard0_other_members_of_cis_owner", "security_definer", "third_owner"):
            self.assertIn(reason, summary)
        self.assertNotIn("kind_not_moved", summary)

    def test_before_rl002(self):
        lines = run(FakeConn(owner=None, login={"login": "aa_cis_admin", "in_owner": None, "in_app": True,
                                                 "v244": True, "v245": False}))
        self.assertIn("SCRIPT cis_owner exists=f (apply rl-002 first)", lines)
        self.assertTrue(re.search(r"reasons=.*guard0_cis_owner_missing", lines[-1]))

    def test_prints_no_row_values(self):
        """Names and counts only: no query reads a table's rows (only catalogs and the registry flags)."""
        for name in ("LOGIN_SQL", "OWNER_ROLE_SQL", "SCHEMAS_SQL", "MOVE_SQL", "REFUSE_OWNER_SQL", "SECDEF_SQL",
                     "RLS_SQL", "OWNER_POLICY_SQL", "DEFAULT_ACL_SQL", "VIEWS_SQL", "LOCK_SQL"):
            q = _norm(getattr(script, name))
            tables = set(re.findall(r"\b(?:FROM|JOIN)\s+([a-z_]+\.[a-z_]+)", q)) - {"shared.schema_versions"}
            self.assertTrue(all(t.startswith("pg_catalog.") for t in tables), (name, tables))


if __name__ == "__main__":
    unittest.main()
