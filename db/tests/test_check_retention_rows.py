"""Unit tests for db/check_retention_rows.py (data standards DM-7.1, AA-929).

Run: python3 -m unittest discover -s db/tests -v
"""
import io
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import check_retention_rows as crr  # noqa: E402

REGISTRY = """# Part B

## 6. PII and privacy

| ID | Rule |
|---|---|
| DM-6.1 | `crm.not_a_retention_row` is named here, outside section 7 |

## 7. Retention and archival

| ID | Rule | Why | Enforced by |
|---|---|---|---|
| DM-7.1 | Every table has a row. `crm.rule_text_only` is cited in a rule, not a table row | x | Review |

| Table | Owner | Raw window | Rollup / after expiry | Archive before delete |
|---|---|---|---|---|
| `shared.llm_call_log` | CIS | **180 days** | rollup | Yes |
| `crm.traveler`, `crm.traveler_health`, `crm.trip` | CRM | until the agency deletes | — | No |
| `crm.audit_event` (monthly partitions) | CRM | **12 months** | — | Yes |
| `crm.otp_challenge` | CRM | 24 h | — | No |

## 8. Access management

| `crm.after_section_seven` | CRM | x | — | — |
"""


class RegistryTest(unittest.TestCase):
    def test_names_from_the_first_column_of_section_7_only(self):
        names = crr.registry_tables(REGISTRY)
        self.assertEqual(names, {"shared.llm_call_log", "crm.traveler", "crm.traveler_health", "crm.trip",
                                 "crm.audit_event", "crm.otp_challenge"})

    def test_missing_section_or_rows_fail_closed(self):
        with self.assertRaises(crr.RegistryError):
            crr.registry_tables("# nothing here\n")
        with self.assertRaises(crr.RegistryError):
            crr.registry_tables("## 7. Retention and archival\n\nno table\n\n## 8. Next\n")

    def test_real_registry_parses_when_the_root_repo_is_next_door(self):
        base = os.environ.get("AA_ECOSYS_ROOT") or Path(__file__).resolve().parents[4]   # workspace layout
        real = Path(base) / "docs" / "architecture" / "data-standards" / "02-data-management.md"
        if not real.is_file():
            self.skipTest("AA-Ecosys root repo not checked out next to this repo")
        names = crr.registry_tables(real.read_text(encoding="utf-8"))
        self.assertIn("shared.llm_call_log", names)


class CreatedTablesTest(unittest.TestCase):
    def tables(self, *sqls):
        return set(crr.created_tables([(f"db/migrations/crm/{i:03d}_x.sql", s) for i, s in enumerate(sqls, 1)], "crm"))

    def test_forms(self):
        sql = """-- CREATE TABLE crm.in_a_comment (id int);
BEGIN;
CREATE TABLE crm.traveler (id uuid PRIMARY KEY, note text DEFAULT 'CREATE TABLE crm.in_a_string ()');
create table if not exists crm.trip (id uuid);
CREATE UNLOGGED TABLE "crm"."otp_challenge" (id uuid);
CREATE TABLE audit_event (id bigint, at timestamptz) PARTITION BY RANGE (at);
CREATE TABLE crm.audit_event_2026_11 PARTITION OF crm.audit_event FOR VALUES FROM ('2026-11-01') TO ('2026-12-01');
CREATE TEMP TABLE scratch (id int);
CREATE VIEW crm.v_x AS SELECT 1;
DO $$ BEGIN EXECUTE 'CREATE TABLE crm.dynamic (id int)'; END $$;
COMMIT;
"""
        self.assertEqual(self.tables(sql), {"crm.traveler", "crm.trip", "crm.otp_challenge", "crm.audit_event"})

    def test_drop_and_rename_in_later_files(self):
        self.assertEqual(self.tables("CREATE TABLE crm.a (id int); CREATE TABLE crm.b (id int);",
                                     "DROP TABLE IF EXISTS crm.a, crm.zzz CASCADE;",
                                     "ALTER TABLE crm.b RENAME TO c;"), {"crm.c"})

    def test_where_points_at_the_creating_file_and_line(self):
        live = crr.created_tables([("db/migrations/crm/001_x.sql", "BEGIN;\n\nCREATE TABLE crm.t (id int);\n")], "crm")
        self.assertEqual(live, {"crm.t": "db/migrations/crm/001_x.sql:3"})


class CheckTest(unittest.TestCase):
    def make_repo(self, layout):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        for rel, body in layout.items():
            p = root / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(body, encoding="utf-8")
        return root

    def run_main(self, root, *extra, github_actions=""):
        # Pin GITHUB_ACTIONS: in Actions main() adds a "::error" annotation after each FAIL line, so a test
        # that inherits the runner env would see every message twice (AA-929 review).
        out = io.StringIO()
        with mock.patch.dict(os.environ, {"GITHUB_ACTIONS": github_actions}):
            code = crr.main(["--repo-root", str(root), *extra], out=out)
        return code, out.getvalue()

    @staticmethod
    def fail_lines(out, needle="has no row"):
        return [line for line in out.splitlines() if line.startswith("FAIL  ") and needle in line]

    def test_table_without_a_row_fails(self):
        """Done-when E: a table without a DM-7 row fails the PR check."""
        root = self.make_repo({
            "registry.md": REGISTRY,
            "db/migrations/crm/001_base.sql": "BEGIN;\nCREATE TABLE crm.traveler (id uuid);\nCOMMIT;\n",
            "db/migrations/crm/002_more.sql": "BEGIN;\nCREATE TABLE crm.trip (id uuid);\n"
                                              "CREATE TABLE crm.ai_draft (id uuid);\nCOMMIT;\n",
        })
        code, out = self.run_main(root, "--registry", str(root / "registry.md"))
        self.assertEqual(code, 1, out)
        self.assertIn("FAIL  db/migrations/crm/002_more.sql:3: table crm.ai_draft has no row", out)
        self.assertNotIn("crm.traveler has no row", out)
        self.assertIn("3 table(s) in crm", out)

    def test_every_table_with_a_row_passes(self):
        root = self.make_repo({
            "registry.md": REGISTRY,
            "db/migrations/crm/001_base.sql": "CREATE TABLE crm.traveler (id uuid); CREATE TABLE crm.trip (id uuid);",
        })
        code, out = self.run_main(root, "--registry", str(root / "registry.md"))
        self.assertEqual(code, 0, out)
        self.assertIn("0 without a row", out)

    def test_a_name_outside_the_section_7_table_does_not_count(self):
        root = self.make_repo({
            "registry.md": REGISTRY,
            "db/migrations/crm/001_base.sql": "CREATE TABLE crm.rule_text_only (id int);\n"
                                              "CREATE TABLE crm.after_section_seven (id int);\n"
                                              "CREATE TABLE crm.not_a_retention_row (id int);\n",
        })
        code, out = self.run_main(root, "--registry", str(root / "registry.md"))
        self.assertEqual(code, 1)
        self.assertEqual(len(self.fail_lines(out)), 3, out)
        self.assertEqual(out.count("has no row"), 3, out)

    def test_github_actions_adds_one_annotation_per_failure(self):
        """In Actions each FAIL line gets one ::error annotation on its file; the FAIL count is unchanged."""
        root = self.make_repo({
            "registry.md": REGISTRY,
            "db/migrations/crm/001_base.sql": "CREATE TABLE crm.rule_text_only (id int);\n"
                                              "CREATE TABLE crm.after_section_seven (id int);\n",
        })
        code, out = self.run_main(root, "--registry", str(root / "registry.md"), github_actions="true")
        self.assertEqual(code, 1, out)
        self.assertEqual(len(self.fail_lines(out)), 2, out)
        notes = [line for line in out.splitlines() if line.startswith("::error ")]
        self.assertEqual(len(notes), 2, out)
        for note in notes:
            self.assertTrue(note.startswith("::error file=db/migrations/crm/001_base.sql::"), note)
            self.assertIn("has no row", note)
        _, plain = self.run_main(root, "--registry", str(root / "registry.md"))
        self.assertNotIn("::error", plain)

    def test_existing_owners_are_grandfathered(self):
        root = self.make_repo({"db/migrations/booking/001_x.sql": "CREATE TABLE booking.new_thing (id int);"})
        self.assertEqual(self.run_main(root), (0, "no migration copy in crm: nothing to check\n"))
        self.assertEqual(self.run_main(root, "--scoped"), (0, "no\n"))

    def test_scoped_dir_needs_a_readable_registry(self):
        root = self.make_repo({"db/migrations/crm/001_base.sql": "CREATE TABLE crm.traveler (id uuid);"})
        self.assertEqual(self.run_main(root, "--scoped"), (0, "yes\n"))
        self.assertEqual(self.run_main(root)[0], 2)
        code, out = self.run_main(root, "--registry", str(root / "missing.md"))
        self.assertEqual(code, 2)
        self.assertIn("FAIL  retention registry", out)
        (root / "empty.md").write_text("# no section 7\n", encoding="utf-8")
        self.assertEqual(self.run_main(root, "--registry", str(root / "empty.md"))[0], 2)

    def test_this_repo_today(self):
        root = Path(__file__).resolve().parent.parent.parent
        self.assertEqual(crr.main(["--repo-root", str(root), "--scoped"], out=io.StringIO()), 0)


if __name__ == "__main__":
    unittest.main()
