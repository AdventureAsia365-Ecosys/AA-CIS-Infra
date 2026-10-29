"""Pure parts of tools/github/migration_lead_time.py (no GitHub call). Run: python3 -m unittest discover -s tools/github/tests"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import migration_lead_time as lt  # noqa: E402


class LeadTimeTest(unittest.TestCase):
    def test_copied_files_keeps_added_owner_migrations_only(self):
        files = [
            {"filename": "db/migrations/booking/034_itinerary_source_tour_idx.sql", "status": "added"},
            {"filename": "db/migrations/cis/303_x.sql", "status": "modified"},       # an edit is no copy
            {"filename": "db/migrations/roles/001_x.sql", "status": "added"},         # roles/ is no owner dir
            {"filename": "db/run_migration.py", "status": "modified"},
        ]
        self.assertEqual(lt.copied_files(files), [("booking", "034_itinerary_source_tour_idx.sql", "034")])

    def test_version_key_per_owner(self):
        self.assertEqual([lt.version_key(o, "034") for o in ("cis", "booking", "tripplanner", "crm")],
                         ["034", "bk-034", "tp-034", "crm-034"])

    def test_minutes_between(self):
        self.assertEqual(lt.minutes_between("2026-10-29T07:00:00Z", "2026-10-29T07:25:30Z"), 25.5)
        self.assertIsNone(lt.minutes_between(None, "2026-10-29T07:25:30Z"))

    def test_apply_from_jobs(self):
        jobs = [
            {"name": "Plan (bytes, classify, forecast; no AWS)", "conclusion": "success", "completed_at": "t1"},
            {"name": "Apply on Dev (dev-db-auto)", "conclusion": "success", "completed_at": "2026-10-29T07:10:00Z"},
            {"name": "Isolation probe (blocking) / probe", "conclusion": "success",
             "completed_at": "2026-10-29T07:14:00Z"},
        ]
        self.assertEqual(lt.apply_from_jobs(jobs), ("2026-10-29T07:14:00Z", "auto+probe"))
        jobs[2]["conclusion"] = "failure"
        self.assertEqual(lt.apply_from_jobs(jobs), ("2026-10-29T07:10:00Z", "auto"))
        jobs[1]["conclusion"] = "skipped"
        self.assertEqual(lt.apply_from_jobs(jobs), (None, "listed-only"))
        self.assertEqual(lt.apply_from_jobs(jobs[:1]), (None, "unknown"))

    def test_summary_counts_target_and_hand_steps(self):
        a = lt.Row("booking", "034_x.sql", "bk-034", app_merged="2026-10-29T07:00:00Z",
                   applied="2026-10-29T07:20:00Z", applied_how="auto+probe", copy_author="aa-ecosys-ci-bot[bot]")
        b = lt.Row("cis", "303_x.sql", "303", app_merged="2026-10-29T07:00:00Z",
                   applied="2026-10-29T08:00:00Z", applied_how="manual~", copy_author="app/aa-agent")
        s = lt.summarise([a, b], 25)
        self.assertEqual((s["measured"], s["within_target"], s["no_hand_step"], s["max_min"]), (2, 1, 1, 60.0))


if __name__ == "__main__":
    unittest.main()
