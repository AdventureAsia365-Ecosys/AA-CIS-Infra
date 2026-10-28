"""AA-850: a dropped schema may be named only by files up to the drop file (review S1, S255)."""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import check_migration_ownership as c  # noqa: E402


class DroppedSchemaWindow(unittest.TestCase):
    def test_older_file_may_still_grant_on_a_dropped_schema(self):
        errors, _ = c.lint("GRANT USAGE ON SCHEMA acp_silver_s4 TO cis_app;\n", "db/migrations/cis/245_x.sql")
        self.assertEqual(errors, [])

    def test_a_later_file_cannot_bring_a_dropped_schema_back(self):
        sql = "CREATE SCHEMA acp_silver_s4;\nCREATE TABLE acp_silver_s4.x (id int);\n"
        errors, _ = c.lint(sql, "db/migrations/cis/300_x.sql")
        self.assertTrue(errors and "acp_silver_s4" in errors[0])

    def test_the_window_ends_at_a_known_drop_file(self):
        self.assertEqual(c.DROPPED_SCHEMAS_LAST_FILE["cis"], 299)


if __name__ == "__main__":
    unittest.main()
