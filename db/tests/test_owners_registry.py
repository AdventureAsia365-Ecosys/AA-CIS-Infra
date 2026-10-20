"""db/owners.yaml is the one owner registry (DM-1.2, X1 plan S1 item 7). The runner, the guards and the
DB Migrate workflow keep their own copies of the facts they need (standard library only, no YAML in the
ECS task); this test fails as soon as one of them disagrees with the registry.

Needs PyYAML: the Migration Copy Guard "Guard unit tests" step (the PR gate) and the DB Schema Dump
"Unit tests" step install it. Without PyYAML (a local run, another caller) the module is skipped,
not failed. The DB Migrate ECS task never runs these tests (it gets only run_migration.py + the SQL).
Run: python3 -m unittest discover -s db/tests -v
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

try:
    import yaml
except ImportError:                                  # optional outside CI: skip, do not error
    raise unittest.SkipTest("PyYAML is not installed (pip install pyyaml==6.0.2): owners.yaml mirror test skipped")

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "db"))

import check_migration_copies as guard  # noqa: E402
import isolation_probe as probe  # noqa: E402
import rls_catalogue_rules as rls  # noqa: E402
import run_migration as rm  # noqa: E402

REGISTRY = yaml.safe_load((ROOT / "db" / "owners.yaml").read_text(encoding="utf-8"))
OWNERS = REGISTRY["owners"]
SCHEMA_OWNERS = {k: v for k, v in OWNERS.items() if not v.get("native")}
WORKFLOW = yaml.safe_load((ROOT / ".github" / "workflows" / "db-migrate.yml").read_text(encoding="utf-8"))
ROLE_RE = re.compile(r"^[a-z][a-z0-9_]*$")

OWNER_KEYS = {"repo", "path", "key_prefix", "anchor_schema", "schemas", "owner_role", "owner_role_today",
              "owner_transfer_key", "runtime_roles", "runtime_roles_today", "runtime_secrets",
              "runtime_privileges", "job_table", "job_kind_prefix", "idle_exempt_kinds", "set_local_roles",
              "role_lint_from", "consumer_grants"}
OPTIONAL_KEYS = {"view_owner_roles", "rls_enable_only_allowlist", "runtime_privileges_from", "owner_grants",
                 "rls_parity_tables"}


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
        # The three apps and roles/ always exist; a new owner (ADR 0008 playbook) is added in owners.yaml and the
        # mirrors this file compares, never here (AA-826 dry run). Owner names are migration dir names.
        self.assertLessEqual({"cis", "booking", "tripplanner", "roles"}, set(OWNERS))
        for name in OWNERS:
            self.assertRegex(name, r"^[a-z]+$")
        self.assertEqual([n for n, o in OWNERS.items() if o.get("native")], ["roles"])

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
                key = o["owner_transfer_key"]
                self.assertRegex(str(key), rf"^{re.escape(o['key_prefix'])}[0-9]{{3}}$")
                self.assertEqual(set(o["runtime_secrets"]), set(o["runtime_roles"]))   # the probe logs in as each
                self.assertLessEqual(set(o["runtime_privileges"]), set(o["runtime_roles"]))
                for role, rp in o["runtime_privileges"].items():
                    self.assertEqual(set(rp), {"schemas", "objects", "default_acl"}, role)
                    self.assertLessEqual(set(rp["schemas"]), set(o["schemas"]), role)
                    self.assertEqual(set(rp["objects"]), set(probe.OBJECT_KINDS), role)
                    self.assertLessEqual(set(rp["default_acl"]), set(probe.DEFACL_OBJTYPE), role)
                if "runtime_privileges_from" in o:
                    self.assertIn(str(o["runtime_privileges_from"]), probe.VERSION_KEYS)

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
                    self.assertLessEqual({"grantee", "privilege", "object", "status", "source"}, set(g))
                    self.assertLessEqual(set(g), {"grantee", "privilege", "object", "status", "source",
                                                  "expected_from"})
                    self.assertIn(g["status"], ("contract", "grandfathered"))
                    self.assertIn(g["grantee"], runtime)
                    self.assertNotEqual(runtime[g["grantee"]], name)
                    if "expected_from" in g:
                        # The owner's own key (it creates the object and the grant), named in the source too.
                        self.assertRegex(g["expected_from"], rf"^{re.escape(o['key_prefix'])}[0-9]{{3}}$")
                        self.assertIn(g["expected_from"], g["source"])
                        self.assertEqual(g["status"], "contract")

    def test_owner_grants_name_other_owners_owner_roles(self):
        # Cross-owner grants to NOLOGIN owner roles (CIS 243: what DB Migrate needs to register a file run as
        # bk_owner / tp_owner). Never to a runtime role (those are consumer_grants) or to the dir's own owner.
        owner_roles = {o["owner_role"]: n for n, o in SCHEMA_OWNERS.items()}
        for name, o in SCHEMA_OWNERS.items():
            for g in o.get("owner_grants", []):
                with self.subTest(owner=name, grant=g):
                    self.assertEqual(set(g), {"grantee", "privilege", "object", "status", "source"})
                    self.assertEqual(g["status"], "contract")
                    self.assertIn(g["grantee"], owner_roles)
                    self.assertNotEqual(owner_roles[g["grantee"]], name)
                    self.assertNotIn("GRANT OPTION", g["privilege"].upper())

    def test_cis_243_owner_grants(self):
        grants = {(g["grantee"], g["object"]): g["privilege"] for g in OWNERS["cis"]["owner_grants"]}
        for role in ("bk_owner", "tp_owner"):
            self.assertEqual(grants[(role, "shared (schema)")], "USAGE")
            self.assertEqual(grants[(role, "shared.schema_versions")], "SELECT, INSERT")

    def test_roles_entry(self):
        r = OWNERS["roles"]
        self.assertEqual((r["repo"], r["path"], r["key_prefix"], r["native"], r["runs_as"]),
                         ("AA-CIS-Infra", "db/migrations/roles", "rl-", True, "master"))


class MirrorsAgreeTest(unittest.TestCase):
    def test_run_migration_constants(self):
        self.assertEqual(rm.MASTER_ROLE, REGISTRY["master_role"])
        self.assertEqual(rm.MASTER_SECRET, REGISTRY["master_secret"])          # X1 S22 in-task master DSN
        self.assertEqual(rm.ROLES_DIR, "roles")
        self.assertEqual(set(rm.OWNER_DIRS), set(SCHEMA_OWNERS))
        for name, o in SCHEMA_OWNERS.items():
            with self.subTest(owner=name):
                d = rm.OWNER_DIRS[name]
                self.assertEqual(d.anchor_schema, o["anchor_schema"])
                self.assertEqual(list(d.schemas), o["schemas"])
                self.assertEqual(d.set_local_roles, frozenset(o["set_local_roles"]))
                self.assertEqual(d.role_lint_from, o["role_lint_from"])
                self.assertEqual(d.view_owner_roles, frozenset(o.get("view_owner_roles", [])))
        self.assertEqual(set(rm.OWNER_SCHEMAS), {s for o in SCHEMA_OWNERS.values() for s in o["schemas"]})

    def test_isolation_probe_constants(self):
        self.assertEqual(probe.MASTER_ROLE, REGISTRY["master_role"])
        self.assertEqual(set(probe.OWNERS), set(SCHEMA_OWNERS))
        for name, o in SCHEMA_OWNERS.items():
            with self.subTest(owner=name):
                p = probe.OWNERS[name]
                self.assertEqual(list(p.schemas), o["schemas"])
                self.assertEqual(p.owner_role, o["owner_role"])
                self.assertEqual(p.transfer_key, str(o["owner_transfer_key"]))
                self.assertEqual(dict(p.runtime_secrets), o["runtime_secrets"])
                self.assertEqual(p.view_owner_roles, frozenset(o.get("view_owner_roles", [])))
                self.assertEqual(p.anchor_schema, o["anchor_schema"])
                self.assertEqual(p.runtime_privileges_from, str(o.get("runtime_privileges_from", "")))
                self.assertEqual({rp.role: {"schemas": list(rp.schemas),
                                            "objects": {k: list(v) for k, v in rp.objects},
                                            "default_acl": {k: list(v) for k, v in rp.default_acl}}
                                  for rp in p.runtime_privileges}, o["runtime_privileges"])
        # Contract consumer grants on one named object (wildcards such as catalog.* are left to the dump).
        single = re.compile(r"^[a-z_]+\.[a-z_]+(\([a-z, ]*\))?$")
        expected = {(g["grantee"], tuple(x.strip() for x in g["privilege"].split(",")), g["object"],
                     str(g.get("expected_from", "")))
                    for o in SCHEMA_OWNERS.values() for g in o["consumer_grants"]
                    if g["status"] == "contract" and single.match(g["object"])}
        self.assertEqual(set(probe.CONSUMER_GRANTS), expected)
        # A keyed grant is only checked in its own cell; its key must be a state key the probe reads.
        for key in probe.CONSUMER_GRANT_KEYS:
            self.assertIn(key, probe.VERSION_KEYS)
        self.assertEqual(probe.RLS_ENABLE_ONLY_ALLOWLIST,
                         frozenset(OWNERS["cis"].get("rls_enable_only_allowlist", [])))
        # X1 S16 (CIS 244, S243): the RLS parity tables, sorted, all in CIS runtime schemas.
        self.assertEqual(list(probe.RLS_PARITY_TABLES), OWNERS["cis"]["rls_parity_tables"])
        self.assertEqual(OWNERS["cis"]["rls_parity_tables"], sorted(OWNERS["cis"]["rls_parity_tables"]))
        for t in probe.RLS_PARITY_TABLES:
            self.assertIn(t.split(".")[0], probe.CIS_RUNTIME_SCHEMAS, t)
        for v in (str(o["owner_transfer_key"]) for o in SCHEMA_OWNERS.values()):
            self.assertIn(v, probe.VERSION_KEYS)

    def test_migrator_task_definition_secrets(self):
        """X1 S22: the migrator task definition injects db_migrator's DSN; the master stays readable in the task
        (task role) only, for roles/ files, set-password and run-script (rm.MASTER_SECRET)."""
        self.assertEqual(REGISTRY["password_roles"][REGISTRY["migrator_role"]], REGISTRY["migrator_secret"])
        self.assertNotEqual(REGISTRY["migrator_secret"], REGISTRY["master_secret"])
        tf = (ROOT / "accounts" / "aa365" / "db_migrator.tf").read_text(encoding="utf-8")
        self.assertIn('name                    = "${var.project}/${var.environment}/db-migrator"', tf)
        self.assertRegex(tf, r"\{ name = local\.db_migrate_dsn_env_name, valueFrom = "
                             r"aws_secretsmanager_secret\.db_migrator\.arn \}")
        execution = tf.split('Sid      = "InjectMigratorDsn"', 1)[1].split("}", 1)[0]
        self.assertIn("Resource = [aws_secretsmanager_secret.db_migrator.arn]", execution)
        self.assertNotIn("rds_secret_arn", execution)
        task_secrets = tf.split("db_migrate_task_secret_arns = [", 1)[1].split("]", 1)[0]
        self.assertIn("module.secrets.rds_secret_arn", task_secrets)            # the in-task master read
        self.assertIn("aws_secretsmanager_secret.db_migrator.arn", task_secrets)  # set-password db_migrator
        # The isolation probe never logs in as the master: its catalog login is the task's DATABASE_URL
        # (db_migrator), every isolation cell uses a runtime role's own secret.
        self.assertNotIn(REGISTRY["master_secret"], probe.RUNTIME_SECRETS.values())
        self.assertNotIn(REGISTRY["migrator_secret"], probe.RUNTIME_SECRETS.values())
        src = (ROOT / "db" / "isolation_probe.py").read_text(encoding="utf-8")
        self.assertIn('else os.environ.get("DATABASE_URL")', src)
        self.assertNotIn(REGISTRY["master_secret"] + '"', src)

    def test_password_roles(self):
        # X1 S12 set-password: runner allowlist, workflow role regex and the probe marker agree with the registry.
        roles = REGISTRY["password_roles"]
        self.assertEqual(rm.PASSWORD_ROLES, roles)
        self.assertEqual(roles["cis_app"], OWNERS["cis"]["runtime_secrets"]["cis_app"])   # the probe's login secret
        self.assertIn(REGISTRY["migrator_role"], roles)
        self.assertNotIn(REGISTRY["master_role"], roles)
        self.assertEqual(rm.PASSWORD_MARKER, probe.PASSWORD_MARKER)
        _, run = validate_step()
        regex = re.search(r'=~ \^\(([a-z_|]+)\)\$', run).group(1)
        self.assertEqual(set(regex.split("|")), set(roles))

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

    def test_rls_catalogue_rules_owner_maps(self):
        """X2 guard: SCHEMA_OWNERS (rule e, rule g) and ROLE_OWNERS (rule g) mirror the registry."""
        expected = {s: name for name, o in SCHEMA_OWNERS.items() for s in o["schemas"]}
        self.assertEqual({s: o for s, o in rls.SCHEMA_OWNERS.items() if o != "platform"}, expected)
        self.assertEqual({s for s, o in rls.SCHEMA_OWNERS.items() if o == "platform"}, {"public"})
        roles = {}
        for name, o in SCHEMA_OWNERS.items():
            for r in [o["owner_role"], *o["runtime_roles"], *o.get("view_owner_roles", [])]:
                roles[r] = name
        self.assertEqual(rls.ROLE_OWNERS, roles)
        self.assertNotIn(REGISTRY["master_role"], rls.ROLE_OWNERS)
        self.assertNotIn(REGISTRY["migrator_role"], rls.ROLE_OWNERS)

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
        self.assertEqual(inputs["mode"]["options"], ["check", "apply", "set-password", "run-script"])


@unittest.skipUnless(shutil.which("bash") and shutil.which("jq"), "bash and jq run the DB Migrate validate step")
class DbMigrateValidateStepTest(unittest.TestCase):
    """Runs the DB Migrate "Validate input" step itself (bash, no AWS) for one file per owner of owners.yaml: the
    step accepts the path and computes the version key with the owner's prefix (AA-826: a new owner is picked up by
    DB Migrate's validation, not only matched by a regex compare). The file is a throwaway copy in a temp tree."""

    SQL = ("-- registry probe (AA-826)\nBEGIN;\nSELECT 1;\n"
           "INSERT INTO shared.schema_versions (version, description) VALUES ('{key}', 'probe');\nCOMMIT;\n")

    def run_step(self, tmp: Path, migration: str) -> tuple[int, dict, str]:
        _, run = validate_step()
        out, summary = tmp / "out.txt", tmp / "summary.md"
        env = {"PATH": os.environ.get("PATH", ""), "MODE": "check", "ENVIRONMENT": REGISTRY["environments"][0],
               "MIGRATION": migration, "OVERRIDE_BUSY_JOBS": "",
               "GITHUB_OUTPUT": str(out), "GITHUB_STEP_SUMMARY": str(summary)}
        p = subprocess.run(["bash", "-e", "-c", run], cwd=tmp, env=env, capture_output=True, text=True, timeout=60)
        outputs = dict(line.split("=", 1) for line in out.read_text().splitlines()) if out.exists() else {}
        return p.returncode, outputs, p.stdout + p.stderr

    def test_every_owner_dir_is_accepted_with_its_key_prefix(self):
        for name, o in OWNERS.items():
            with self.subTest(owner=name), tempfile.TemporaryDirectory() as d:
                tmp = Path(d)
                shutil.copytree(ROOT / "db", tmp / "db", ignore=shutil.ignore_patterns("migrations", "__pycache__"))
                key = f"{o['key_prefix']}999"
                f = tmp / "db" / "migrations" / name / "999_registry_probe.sql"
                f.parent.mkdir(parents=True)
                f.write_text(self.SQL.format(key=key), encoding="utf-8")
                code, outputs, log = self.run_step(tmp, f"{name}/999_registry_probe.sql")
                self.assertEqual(code, 0, log)
                self.assertEqual(outputs.get("version"), key, log)

    def test_unknown_owner_dir_is_refused(self):
        with tempfile.TemporaryDirectory() as d:
            tmp = Path(d)
            code, _, log = self.run_step(tmp, "notanowner/999_registry_probe.sql")
            self.assertNotEqual(code, 0)
            self.assertIn("migration must look like", log)


if __name__ == "__main__":
    unittest.main()
