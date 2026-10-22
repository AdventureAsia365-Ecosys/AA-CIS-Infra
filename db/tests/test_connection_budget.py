"""Unit tests for db/check_connection_budget.py (AA-879, U-61). No network: app sources are a dict.

Run: python3 -m unittest discover -s db/tests -v
"""
import copy
import datetime as dt
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import check_connection_budget as budget  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
TODAY = dt.date(2026, 10, 22)

ECS_MAIN = """
resource "aws_appautoscaling_target" "api" {
  max_capacity       = 7
  min_capacity       = var.service_desired_count
}
"""
ECS_VARS = """
variable "worker_max_count" {
  type    = number
  default = 3
}
"""
RDS_VARS = """
variable "instance_class" {
  type    = string
  default = "db.t4g.small"
}
"""
OBS = "locals {\n  rds_max_connections = 181\n}\n"
ROLES = "-- old: ALTER ROLE app CONNECTION LIMIT 1;\nALTER ROLE app LOGIN CONNECTION LIMIT 20;\n"

MANIFEST = {
    "ceiling_pct": 75,
    "max_connections": {
        "tf_file": "obs.tf",
        "tf_regex": r"rds_max_connections\s*=\s*(\d+)",
        "instance_class": {"tf_file": "modules/rds/variables.tf",
                           "tf_regex": r"variable \"instance_class\" \{[^}]*?default\s*=\s*\"([^\"]+)\"",
                           "override_glob": "accounts/*.tf",
                           "override_regex": r"module \"rds\" \{[^}]*?instance_class\s*=\s*\"([^\"]+)\""},
        "by_class": {"db.t4g.small": 181},
    },
    "role_limits": {"app": 20},
    "pools": [
        {"name": "api", "role": "app", "max_size": 2,
         "source": {"repo": "App", "path": "main.py", "regex": r"max_size=(\d+)"},
         "processes": {"tf_file": "modules/ecs/main.tf",
                       "tf_regex": r"resource \"aws_appautoscaling_target\" \"api\" \{[^}]*?max_capacity\s*=\s*(\d+)"}},
        {"name": "worker", "role": "app", "max_size": 5,
         "source": {"repo": "App", "path": "worker.py", "regex": r"^DEFAULT\s*=\s*(\d+)", "transform": "worker_pool"},
         "processes": {"tf_file": "modules/ecs/variables.tf",
                       "tf_regex": r"variable \"worker_max_count\" \{[^}]*?default\s*=\s*(\d+)",
                       "override_glob": "accounts/*.tf", "override_regex": r"worker_max_count\s*=\s*(\d+)"}},
    ],
    "reserves": [{"name": "admin", "connections": 10}],
    "accepted_overages": [],
}
SOURCES = {("App", "main.py"): b"pool = create_pool(dsn, max_size=2)\n", ("App", "worker.py"): b"DEFAULT = 3\n"}


class BudgetTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        for rel, text in {
            "modules/ecs/main.tf": ECS_MAIN, "modules/ecs/variables.tf": ECS_VARS,
            "modules/rds/variables.tf": RDS_VARS, "obs.tf": OBS,
            "db/migrations/roles/001_x.sql": ROLES, "accounts/main.tf": "# nothing\n",
        }.items():
            p = self.root / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(text)
        (self.root / "db" / "migrations" / "cis").mkdir(parents=True, exist_ok=True)
        self.m = copy.deepcopy(MANIFEST)

    def tearDown(self):
        self.tmp.cleanup()

    def run_check(self, fetch=None):
        return budget.check(self.m, self.root, TODAY, fetch)

    def test_within_budget_passes(self):
        # api 2 x 7 = 14 + worker 5 x 3 = 15 = 29: fits a limit of 29.
        self.m["role_limits"]["app"] = 29
        (self.root / "db/migrations/roles/001_x.sql").write_text("ALTER ROLE app CONNECTION LIMIT 29;\n")
        errors, warnings, report = self.run_check(fetch=lambda r, p: SOURCES.get((r, p)))
        self.assertEqual(errors, [])
        self.assertIn("total 39 / ceiling 135", report)

    def test_role_over_limit_fails(self):
        errors, _, _ = self.run_check()
        self.assertTrue(any("role:app: worst case 29 > 20" in e for e in errors), errors)

    def test_terraform_increase_is_caught(self):
        self.m["role_limits"]["app"] = 29
        (self.root / "db/migrations/roles/001_x.sql").write_text("ALTER ROLE app CONNECTION LIMIT 29;\n")
        (self.root / "accounts/main.tf").write_text('module "ecs" {\n  worker_max_count = 4\n}\n')
        errors, _, _ = self.run_check()
        self.assertTrue(any("role:app: worst case 34 > 29" in e for e in errors), errors)

    def test_accepted_overage_passes_but_growth_fails(self):
        self.m["accepted_overages"] = [{"check": "role:app", "accept_up_to": 29, "until": "2026-11-30", "reason": "r"}]
        errors, warnings, _ = self.run_check()
        self.assertEqual(errors, [])
        self.assertTrue(any("accepted until 2026-11-30" in w for w in warnings))
        self.m["accepted_overages"][0]["accept_up_to"] = 28
        errors, _, _ = self.run_check()
        self.assertTrue(any("makes an accepted overage worse" in e for e in errors), errors)

    def test_accepted_overage_expiry_rules(self):
        self.m["accepted_overages"] = [{"check": "role:app", "accept_up_to": 29, "until": "2026-10-01", "reason": "r"}]
        errors, _, _ = self.run_check()
        self.assertTrue(any("expired on 2026-10-01" in e for e in errors), errors)
        self.m["accepted_overages"][0]["until"] = "2027-03-01"
        errors, _, _ = self.run_check()
        self.assertTrue(any("more than 60 days ahead" in e for e in errors), errors)

    def test_role_limit_must_match_role_files(self):
        self.m["role_limits"]["app"] = 25
        errors, _, _ = self.run_check()
        self.assertTrue(any("manifest limit 25, role files set 20" in e for e in errors), errors)

    def test_instance_class_change_needs_a_measured_max(self):
        (self.root / "accounts/main.tf").write_text('module "rds" {\n  instance_class = "db.t4g.medium"\n}\n')
        errors, _, _ = self.run_check()
        self.assertTrue(any("db.t4g.medium has no max_connections" in e for e in errors), errors)

    def test_source_drift_is_caught(self):
        drift = dict(SOURCES)
        drift[("App", "worker.py")] = b"DEFAULT = 8\n"  # max(5, 8 + 2) = 10, manifest says 5
        errors, _, _ = self.run_check(fetch=lambda r, p: drift.get((r, p)))
        self.assertTrue(any("manifest max_size 5, App main has 10" in e for e in errors), errors)

    def test_committed_manifest_matches_this_repo(self):
        manifest = json.loads((REPO / "db" / "connection_budget.json").read_text())
        errors, _, report = budget.check(manifest, REPO, TODAY, None)
        self.assertEqual(errors, [], "\n".join(report))


if __name__ == "__main__":
    unittest.main()
