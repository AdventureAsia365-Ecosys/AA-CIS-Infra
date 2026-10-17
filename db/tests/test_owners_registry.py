"""db/owners.yaml is the one owner registry (DM-1.2, X1 plan S1 item 7). The runner, the guards and the
DB Migrate workflow keep their own copies of the facts they need (standard library only, no YAML in the
ECS task); this test fails as soon as one of them disagrees with the registry.

Needs PyYAML (CI installs it in the Migration Copy Guard "Guard unit tests" step).
Run: python3 -m unittest discover -s db/tests -v
"""
import re
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "db"))

import check_migration_copies as guard  # noqa: E402
import run_migration as rm  # noqa: E402

REGISTRY = yaml.safe_load((ROOT / "db" / "owners.yaml").read_text(encoding="utf-8"))
OWNERS = REGISTRY["owners"]
SCHEMA_OWNERS = {k: v for k, v in OWNERS.items() if not v.get("native")}
WORKFLOW = yaml.safe_load((ROOT / ".github" / "workflows" / "db-migrate.yml").read_text(encoding="utf-8"))
ROLE_RE = re.compile(r"^[a-z][a-z0-9_]*$")

OWNER_KEYS = {"repo", "path", "key_prefix", "anchor_schema", "schemas", "owner_role", "owner_role_today",
              "runtime_roles", "runtime_roles_today", "job_table", "job_kind_prefix", "idle_exempt_kinds",
              "set_local_roles", "role_lint_from", "consumer_grants"}
OPTIONAL_KEYS = {"view_owner_roles"}


def validate_step():
    on = WORKFLOW.get("on", WORKFLOW.get(True))          # YAML 1.1 reads a bare `on` as True
    steps = WORKFLOW["jobs"]["migrate"]["steps"]
    run = next(s["run"] for s in steps if s.get("name") == "Validate input")
    return on, run


class RegistryShapeTest(unittest.TestCase):
    def test_top_level(self):
        self.assertEqual(REGISTRY["version"], 1)
        self.assertEqual(REGISTRY["environments"], ["dev"])
        self.assertRegex(REGISTRY["master_role"], ROLE_RE)
        self.assertEqual(set(OWNERS), {"cis", "booking", "tripplanner", "roles"})

    def test_owner_entries(self):
        prefixes = set()
        for name, o in SCHEMA_OWNERS.items():
            with self.subTest(owner=name):
                self.assertEqual(set(o) - OPTIONAL_KEYS, OWNER_KEYS)
                self.assertRegex(o["key_prefix"], r"^([a-z]+-)?$")
                self.assertNotIn(o["key_prefix"], prefixes)
                prefixes.add(o["key_prefix"])
                self.assertIn(o["anchor_schema"], o["schemas"])
                self.assertEqual(o["schemas"], sorted(o["schemas"]))
                for r in [o["owner_role"], o["owner_role_today"], *o["runtime_roles"], *o["runtime_roles_today"],
                          *o["set_local_roles"]]:
                    self.assertRegex(r, ROLE_RE)
                self.assertNotIn(o["owner_role"], o["runtime_roles"])       # runtime roles own nothing (DM-1.3)
                self.assertRegex(o["job_kind_prefix"], r"^([a-z]+_)?$")
                if o["job_table"] is not None:
                    self.assertTrue(o["job_table"].endswith(".job"))
                    self.assertIn(o["job_table"].split(".")[0], o["schemas"])
                else:
                    self.assertEqual(o["idle_exempt_kinds"], [])
                for kind in o["idle_exempt_kinds"]:
                    self.assertTrue(kind.startswith(o["job_kind_prefix"]), kind)
                self.assertIsInstance(o["role_lint_from"], int)

    def test_schemas_belong_to_one_owner(self):
        seen = {}
        for name, o in SCHEMA_OWNERS.items():
            for s in o["schemas"]:
                self.assertNotIn(s, seen, f"{s} listed by {seen.get(s)} and {name}")
                seen[s] = name
        self.assertNotIn("public", seen)        # public.* leftovers belong to roles/ (master)

    def test_set_local_roles_never_include_tenant_or_master_roles(self):
        # §1.4 of the X1 plan: policies TO r apply to members of r; a migration must not act as the
        # tenant pool role or the master.
        for name, o in SCHEMA_OWNERS.items():
            self.assertFalse({"aa_app_user", REGISTRY["master_role"]} & set(o["set_local_roles"]), name)

    def test_consumer_grants_name_other_owners_runtime_roles(self):
        runtime = {r: n for n, o in SCHEMA_OWNERS.items() for r in o["runtime_roles"]}
        for name, o in SCHEMA_OWNERS.items():
            for g in o["consumer_grants"]:
                with self.subTest(owner=name, grant=g):
                    self.assertEqual(set(g), {"grantee", "privilege", "object", "status", "source"})
                    self.assertIn(g["status"], ("contract", "grandfathered"))
                    self.assertIn(g["grantee"], runtime)
                    self.assertNotEqual(runtime[g["grantee"]], name)

    def test_roles_entry(self):
        r = OWNERS["roles"]
        self.assertEqual((r["repo"], r["path"], r["key_prefix"], r["native"], r["runs_as"]),
                         ("AA-CIS-Infra", "db/migrations/roles", "rl-", True, "master"))


class MirrorsAgreeTest(unittest.TestCase):
    def test_run_migration_constants(self):
        self.assertEqual(rm.MASTER_ROLE, REGISTRY["master_role"])
        self.assertEqual(rm.ROLES_DIR, "roles")
        self.assertEqual(set(rm.OWNER_DIRS), set(SCHEMA_OWNERS))
        for name, o in SCHEMA_OWNERS.items():
            with self.subTest(owner=name):
                d = rm.OWNER_DIRS[name]
                self.assertEqual(d.anchor_schema, o["anchor_schema"])
                self.assertEqual(list(d.schemas), o["schemas"])
                self.assertEqual(d.set_local_roles, frozenset(o["set_local_roles"]))
                self.assertEqual(d.role_lint_from, o["role_lint_from"])
        self.assertEqual(set(rm.OWNER_SCHEMAS), {s for o in SCHEMA_OWNERS.values() for s in o["schemas"]})

    def test_idle_exempt_kinds(self):
        expected = {o["job_table"].split(".")[0]: frozenset(o["idle_exempt_kinds"])
                    for o in SCHEMA_OWNERS.values() if o["job_table"]}
        self.assertEqual(rm.IDLE_EXEMPT_KINDS, expected)

    def test_copy_guard_owners_and_path_re(self):
        self.assertEqual(set(guard.OWNERS), set(OWNERS))
        for name, o in OWNERS.items():
            with self.subTest(owner=name):
                g = guard.OWNERS[name]
                self.assertEqual((g.repo, g.source_dir, g.key_prefix, g.native),
                                 (o["repo"], o["path"], o["key_prefix"], bool(o.get("native"))))
        dirs = re.search(r"\^db/migrations/\(([a-z|]+)\)/", guard.PATH_RE.pattern).group(1)
        self.assertEqual(set(dirs.split("|")), set(OWNERS))

    def test_db_migrate_workflow(self):
        on, run = validate_step()
        inputs = on["workflow_dispatch"]["inputs"]
        self.assertEqual(inputs["environment"]["options"], REGISTRY["environments"])
        self.assertEqual(inputs["environment"]["default"], REGISTRY["environments"][0])
        dirs = re.search(r'=~ \^\(([a-z|]+)\)/', run).group(1)
        self.assertEqual(set(dirs.split("|")), set(OWNERS))
        prefixes = dict(re.findall(r'([a-z]+)\) PREFIX="([^"]*)"', run))
        self.assertEqual(prefixes, {n: o["key_prefix"] for n, o in OWNERS.items()})
        self.assertIn(f'"$ENVIRONMENT" != "{REGISTRY["environments"][0]}"', run)


if __name__ == "__main__":
    unittest.main()
