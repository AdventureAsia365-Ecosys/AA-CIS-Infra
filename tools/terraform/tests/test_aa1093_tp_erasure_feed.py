"""AA-1093 follow-up (S279, DRILL-01): the TripPlanner jobs Lambda reads the CIS erasure request feed every 5 minutes.

modules/environment/tripplanner_jobs.tf:

1. a second EventBridge schedule sends {"op": "erasure_feed"} only (never the daily tick), on the same invoke role and
   function, no flexible window, no delivery retry and a short event age (a missed run is replaced by the next one);
2. the daily tick schedule still sends {"op": "tick"};
3. the reserved concurrency of the function is unchanged (connection budget pool tp-jobs: 1);
4. the not-run alarm counts the tick's own log line, not Invocations (the feed invokes the function all day and would
   hide a stopped tick); the filter is an event metric (no default_value).

Offline: reads the .tf files. Run: python3 -m pytest -q tools/terraform/tests/test_aa1093_tp_erasure_feed.py
"""
import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
TP_JOBS = (ROOT / "modules" / "environment" / "tripplanner_jobs.tf").read_text(encoding="utf-8")
BUDGET = json.loads((ROOT / "db" / "connection_budget.json").read_text(encoding="utf-8"))
ROOT_VARS = (ROOT / "accounts" / "aa365" / "tripplanner_variables.tf").read_text(encoding="utf-8")


def _block(text: str, header: str) -> str:
    start = text.index(header)
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start : i + 1]
    raise AssertionError(f"unclosed block: {header}")


class ErasureFeedScheduleTest(unittest.TestCase):
    def setUp(self):
        self.feed = _block(TP_JOBS, 'resource "aws_scheduler_schedule" "tripplanner_jobs_erasure_feed"')
        self.daily = _block(TP_JOBS, 'resource "aws_scheduler_schedule" "tripplanner_jobs_daily"')

    def test_the_feed_sends_its_op_only_to_the_jobs_function(self):
        self.assertIn('input    = jsonencode({ op = "erasure_feed", source = "aa-1093-erasure-feed" })', self.feed)
        self.assertNotIn('"tick"', self.feed)
        self.assertIn("arn      = aws_lambda_function.tripplanner_jobs.arn", self.feed)
        self.assertIn("role_arn = aws_iam_role.tripplanner_jobs_scheduler.arn", self.feed)
        self.assertIn("group_name  = var.eventbridge_schedule_group_name", self.feed)

    def test_the_daily_tick_is_unchanged(self):
        self.assertIn('input    = jsonencode({ op = "tick", source = "aa-861-daily" })', self.daily)
        self.assertIn("schedule_expression          = var.tripplanner_jobs_schedule_expression", self.daily)

    def test_every_five_minutes_without_window_or_retry(self):
        self.assertIn("schedule_expression          = var.tripplanner_jobs_erasure_feed_schedule_expression",
                      self.feed)
        for text in (TP_JOBS, ROOT_VARS):
            var = _block(text, 'variable "tripplanner_jobs_erasure_feed_schedule_expression"')
            self.assertRegex(var, r'default = "rate\(5 minutes\)"')
        self.assertRegex(self.feed, r'flexible_time_window \{\s*mode = "OFF"\s*\}')
        self.assertIn("maximum_retry_attempts       = 0", self.feed)
        self.assertIn("maximum_event_age_in_seconds = 300", self.feed)

    def test_reserved_concurrency_and_connection_budget_unchanged(self):
        fn = _block(TP_JOBS, 'resource "aws_lambda_function" "tripplanner_jobs"')
        self.assertIn("reserved_concurrent_executions = var.tripplanner_jobs_reserved_concurrency", fn)
        self.assertRegex(ROOT_VARS, r'variable "tripplanner_jobs_reserved_concurrency" \{[^}]*?default\s*=\s*1\b')
        pools = [p for p in json.dumps(BUDGET).split('"name": ') if p.startswith('"tp-jobs"')]
        self.assertEqual(len(pools), 1)


class TickNotRunAlarmTest(unittest.TestCase):
    def setUp(self):
        self.filter = _block(TP_JOBS, 'resource "aws_cloudwatch_log_metric_filter" "tripplanner_jobs_tick"')
        self.alarm = _block(TP_JOBS, 'resource "aws_cloudwatch_metric_alarm" "tripplanner_jobs_not_run"')

    def test_the_filter_counts_the_tick_line_only(self):
        self.assertIn('pattern        = "{ ($.evt = \\"jobs_run\\") && ($.op = \\"tick\\") }"', self.filter)
        self.assertIn("log_group_name = aws_cloudwatch_log_group.tripplanner_jobs.name", self.filter)
        self.assertNotIn("default_value", self.filter)

    def test_the_alarm_reads_the_filter_not_invocations(self):
        self.assertNotIn('"Invocations"', self.alarm)
        self.assertIn("metric_transformation[0].namespace", self.alarm)
        self.assertIn("metric_transformation[0].name", self.alarm)
        self.assertNotIn("dimensions", self.alarm)
        self.assertIn('treat_missing_data  = "breaching"', self.alarm)
        self.assertRegex(self.alarm, r"period\s*=\s*86400")
        self.assertRegex(self.alarm, r"evaluation_periods\s*=\s*2")


if __name__ == "__main__":
    unittest.main()
