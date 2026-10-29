"""AA-993 Phase E slice M3: db/migration_sync.py (the copy PRs ci-bot opens and merges, ADR 0011a).

No network: temp folders stand in for the owner repos' main and this repo's copies.
  python3 -m unittest discover -s db/tests -v
"""
import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "db"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import migration_sync as ms  # noqa: E402
from test_aa993_expand import tx  # noqa: E402

EXPAND = tx("CREATE TABLE booking.aa993_new (id bigint PRIMARY KEY);", version="bk-035")
CONTRACT = tx("ALTER TABLE booking.trip ADD CONSTRAINT c CHECK (true);", version="bk-034", header="")
DESTRUCTIVE = ("-- Migration bk-036: x.\n-- migrate: destructive\nBEGIN;\nDROP TABLE booking.old;\n"
               "INSERT INTO shared.schema_versions (version, applied_at, description) VALUES ('bk-036', now(), 'x');\n"
               "COMMIT;\n")
RULESET = json.loads((ROOT / "tools" / "github" / "infra-main-ruleset.json").read_text())


class Repo:
    def __init__(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.infra, self.owner = base / "infra", base / "AA-Booking" / "migrations"
        (self.infra / "db" / "migrations" / "booking").mkdir(parents=True)
        self.owner.mkdir(parents=True)

    def copy(self, name, sql="-- x\n"):
        (self.infra / "db" / "migrations" / "booking" / name).write_bytes(sql.encode())
        self.main(name, sql)

    def main(self, name, sql):
        (self.owner / name).write_bytes(sql.encode())

    def plan(self, registered=None):
        return ms.plan(self.infra, {"booking": self.owner}, registered)


class PlanTest(unittest.TestCase):
    def setUp(self):
        self.r = Repo()

    def tearDown(self):
        self.r.tmp.cleanup()

    def test_set_difference_finds_a_lower_numbered_late_file(self):
        for n in ("010", "011", "013"):
            self.r.copy(f"{n}_x{n}.sql")
        self.r.main("012_late.sql", EXPAND)          # merged on the owner's main after 013 was copied
        self.r.main("014_next.sql", CONTRACT)
        self.r.main("005_history.sql", "-- before the copy flow\n")     # below the lowest copy: never copied
        out = self.r.plan()
        self.assertEqual([(c["file"], c["branch"]) for c in out["copies"]],
                         [("012_late.sql", "bot/migration-copy/booking-012"),
                          ("014_next.sql", "bot/migration-copy/booking-014")])
        late, nxt = out["copies"]
        self.assertTrue(late["out_of_order"])
        self.assertEqual(late["labels"], ["migration:expand", "out-of-order"])
        self.assertEqual((nxt["out_of_order"], nxt["labels"]), (False, ["migration:contract"]))

    def test_out_of_order_uses_the_registered_keys_when_a_dump_exists(self):
        self.r.copy("010_a.sql")
        self.r.copy("013_c.sql")                     # copied, not applied yet
        self.r.main("012_b.sql", EXPAND)
        self.assertFalse(self.r.plan({"bk-010"})["copies"][0]["out_of_order"])
        self.assertTrue(self.r.plan({"bk-010", "bk-013"})["copies"][0]["out_of_order"])

    def test_copy_is_the_owner_bytes_one_file_per_branch(self):
        self.r.copy("033_a.sql")
        self.r.main("034_b.sql", CONTRACT)
        self.r.main("035_c.sql", EXPAND)
        self.r.main("036_d.sql", DESTRUCTIVE)
        copies = self.r.plan()["copies"]
        self.assertEqual(len({c["branch"] for c in copies}), 3)
        for c in copies:
            self.assertEqual(Path(c["source"]).read_bytes(), (self.r.owner / c["file"]).read_bytes())
            self.assertEqual(c["path"], f"db/migrations/booking/{c['file']}")
            self.assertTrue(c["commit"].startswith("chore: copy booking migration "))
            self.assertIn("Refs AA-993", c["commit"])
            self.assertNotRegex(c["commit"], r"(?i)\b(fixes|closes)\b")
        self.assertEqual([c["class"] for c in copies], ["contract", "expand", "destructive"])
        self.assertIn("manual DB Migrate apply needed", copies[0]["body"])
        self.assertIn("migration-apply", copies[1]["body"])

    def test_number_already_used_is_a_conflict_not_a_copy(self):
        self.r.copy("033_a.sql")
        self.r.main("033_renamed.sql", "-- other\n")
        out = self.r.plan()
        self.assertEqual(out["copies"], [])
        self.assertEqual(out["conflicts"][0]["file"], "033_renamed.sql")

    def test_nothing_new_plans_nothing(self):
        self.r.copy("033_a.sql")
        self.assertEqual(self.r.plan(), {"copies": [], "conflicts": [], "out_of_order_basis": "copies"})

    def test_cli_writes_the_plan(self):
        self.r.copy("033_a.sql")
        self.r.main("034_b.sql", EXPAND)
        out = self.r.infra / "plan.json"
        with contextlib.redirect_stdout(io.StringIO()) as buf:
            self.assertEqual(ms.main(["plan", "--repo-root", str(self.r.infra), "--source",
                                      f"booking={self.r.owner}", "--out", str(out)]), 0)
        self.assertIn("SYNC copy booking/034_b.sql -> bot/migration-copy/booking-034", buf.getvalue())
        self.assertEqual(json.loads(out.read_text())["copies"][0]["version"], "bk-034")


def pr(**edit):
    base = {"state": "open", "draft": False, "user": {"login": "aa-ecosys-ci-bot[bot]", "type": "Bot"},
            "head": {"ref": "bot/migration-copy/booking-034", "sha": "abc",
                     "repo": {"full_name": "AdventureAsia365-Ecosys/AA-CIS-Infra"}},
            "base": {"ref": "main", "repo": {"full_name": "AdventureAsia365-Ecosys/AA-CIS-Infra"}}}
    base.update(edit)
    return base


def green():
    return [{"name": c, "status": "completed", "conclusion": "success"} for c in ms.required_contexts(RULESET)]


class MergeCheckTest(unittest.TestCase):
    def setUp(self):
        self.r = Repo()
        self.r.main("034_b.sql", EXPAND)
        self.files = [{"filename": "db/migrations/booking/034_b.sql", "status": "added"}]
        self.req = ms.required_contexts(RULESET)

    def tearDown(self):
        self.r.tmp.cleanup()

    def check(self, p=None, files=None, checks=None, head=EXPAND.encode()):
        return ms.merge_check(p or pr(), self.files if files is None else files,
                              green() if checks is None else checks, head, {"booking": self.r.owner}, self.req)

    def test_required_contexts_come_from_the_ruleset(self):
        self.assertIn("Copies match owner main", self.req)
        self.assertIn("Expand classify", self.req)

    def test_green_single_byte_identical_copy_merges(self):
        self.assertEqual(self.check()[0], 0)

    def test_byte_difference_refuses(self):
        code, why = self.check(head=EXPAND.encode() + b"\n")
        self.assertEqual(code, 1)
        self.assertIn("not byte-identical", why)

    def test_more_than_one_file_or_an_edit_refuses(self):
        two = self.files + [{"filename": "db/run_migration.py", "status": "modified"}]
        self.assertEqual(self.check(files=two)[0], 1)
        self.assertEqual(self.check(files=[{"filename": "db/migrations/booking/034_b.sql", "status": "modified"}])[0], 1)
        self.assertEqual(self.check(files=[{"filename": "db/migrations/booking/035_b.sql", "status": "added"}])[0], 1)

    def test_only_bot_branches_from_this_repo_merge(self):
        self.assertEqual(self.check(pr(user={"login": "someone", "type": "User"}))[0], 1)
        fork = pr(head={"ref": "bot/migration-copy/booking-034", "sha": "abc", "repo": {"full_name": "x/y"}})
        self.assertEqual(self.check(fork)[0], 1)
        other = pr(head={"ref": "feat/x", "sha": "abc", "repo": {"full_name": "AdventureAsia365-Ecosys/AA-CIS-Infra"}})
        self.assertEqual(self.check(other)[0], 1)
        self.assertEqual(self.check(pr(draft=True))[0], 1)

    def test_pending_checks_wait_and_failed_checks_refuse(self):
        checks = green()
        checks[0] = dict(checks[0], status="in_progress", conclusion=None)
        self.assertEqual(self.check(checks=checks)[0], 2)
        self.assertEqual(self.check(checks=green()[1:])[0], 2)          # a required check not started yet
        failed = green() + [{"name": "Docs lint", "status": "completed", "conclusion": "failure"}]
        self.assertEqual(self.check(checks=failed)[0], 1)
        skipped = [dict(c, conclusion="skipped") if c["name"] == "Terraform Plan (dev)" else c for c in green()]
        self.assertEqual(self.check(checks=skipped)[0], 0)

    def test_file_missing_on_the_owner_main_refuses(self):
        (self.r.owner / "034_b.sql").unlink()
        self.assertEqual(self.check()[0], 1)


if __name__ == "__main__":
    unittest.main()
