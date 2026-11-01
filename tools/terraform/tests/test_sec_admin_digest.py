"""AA-873 (S263): offline guards for the Identity Center admin session digest (security_sso_session_digest.tf).

1. Least privilege: the Lambda role holds exactly LookupEvents, Publish on the alerts topic, Get/Put on the one state
   object (plus ListBucket on that key only) and its own log stream; both roles carry the workload boundary.
2. The function reads the alerted permission sets from security_sso_signin.tf (one list, no copy), and its activity
   regions include us-east-1 (global services) and every region the organization region SCP allows
   (accounts/management var.allowed_regions), so no allowed region goes unread.
3. Hourly schedule in the module.eventbridge group (the only group the CI apply role may write), no Lambda retries,
   365-day log group (security log class), an Errors alarm with a runbook link.
4. The live check tool's digest helpers (sec_alert_check.py): config problems and preview leak detection.

Run: python3 -m pytest -q tools/terraform/tests/test_sec_admin_digest.py
"""
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
AA365 = ROOT / "accounts" / "aa365"
sys.path.insert(0, str(ROOT / "tools" / "terraform"))

import sec_alert_check as chk  # noqa: E402

TF = (AA365 / "security_sso_session_digest.tf").read_text(encoding="utf-8")
MGMT_VARS = (ROOT / "accounts" / "management" / "variables.tf").read_text(encoding="utf-8")


def _list_default(text: str, var: str) -> list:
    m = re.search(rf'^variable "{var}" \{{.*?^\s*default\s*=\s*\[([^\]]*)\]', text, re.M | re.S)
    assert m, f"default of var.{var} not found"
    return re.findall(r'"([^"]+)"', m.group(1))


def _resource(kind: str, name: str) -> str:
    m = re.search(rf'^resource "{kind}" "{name}" \{{', TF, re.M)
    assert m, f"{kind}.{name} not found"
    body = TF[m.end():]
    return body[: re.search(r"^\}", body, re.M).start()]


class DigestTerraformTest(unittest.TestCase):
    def test_exec_role_is_least_privilege(self):
        perms = _resource("aws_iam_role_policy", "sec_admin_session_digest_perms")
        actions = sorted(set(re.findall(r'"((?:[a-z0-9-]+):[A-Za-z*]+)"', perms)))
        self.assertEqual(actions, sorted([
            "cloudtrail:LookupEvents", "logs:CreateLogStream", "logs:PutLogEvents", "s3:GetObject", "s3:ListBucket",
            "s3:PutObject", "s3:prefix", "sns:Publish",
        ]))
        self.assertNotIn('Effect   = "Deny"', perms)
        self.assertIn('Resource = "${module.s3.bronze_bucket_arn}/${local.sec_digest_state_key}"', perms)
        self.assertIn('Condition = { StringEquals = { "s3:prefix" = [local.sec_digest_state_key] } }', perms)
        self.assertIn("Resource = aws_sns_topic.alerts.arn", perms)
        # Only LookupEvents is on "*" (no resource-level permission exists for it).
        stars = re.findall(r'Action\s*=\s*\[([^\]]*)\]\s*\n\s*Resource\s*=\s*"\*"', perms)
        self.assertEqual([s.strip() for s in stars], ['"cloudtrail:LookupEvents"'])

    def test_roles_carry_the_workload_boundary_and_stack_names(self):
        for name in ("sec_admin_session_digest_exec", "sec_admin_session_digest_scheduler"):
            with self.subTest(role=name):
                role = _resource("aws_iam_role", name)
                self.assertIn("permissions_boundary = aws_iam_policy.workload_boundary.arn", role)
                self.assertIn('name                 = "${local.sec_digest_fn_name}-', role)
        self.assertIn('sec_digest_fn_name   = "${local.sec_prefix}-admin-session-digest"', TF)

    def test_function_settings(self):
        fn = _resource("aws_lambda_function", "sec_admin_session_digest")
        self.assertIn("ADMIN_PERMISSION_SETS = join(\",\", sort(values(local.sec_sso_admin_permission_sets)))", fn)
        self.assertIn("ACTIVITY_REGIONS      = join(\",\", var.sec_admin_digest_activity_regions)", fn)
        self.assertIn("RUNBOOK_URL           = local.runbook_url.incident", fn)
        self.assertIn('runtime       = "python3.12"', fn)
        self.assertIn('source_dir  = "${path.module}/lambda_src/sec_admin_session_digest"', TF)
        self.assertIn('excludes         = ["__pycache__", "__pycache__/**", "**/*.pyc"]', TF)
        self.assertIn('contains(var.sec_admin_digest_activity_regions, "us-east-1")', TF)
        self.assertIn('sec_digest_saml_regions = distinct(concat(["us-east-1", var.aws_region], '
                      'var.sec_admin_digest_activity_regions))', TF)

    def test_activity_regions_cover_the_scp_allow_list(self):
        digest = _list_default(TF, "sec_admin_digest_activity_regions")
        allowed = _list_default(MGMT_VARS, "allowed_regions")
        self.assertIn("us-west-2", allowed)  # the parse found the real list
        self.assertEqual(sorted(set(allowed) - set(digest)), [], "an SCP-allowed region is never read by the digest")
        self.assertIn("us-east-1", digest)

    def test_schedule_retries_logs_and_alarm(self):
        sch = _resource("aws_scheduler_schedule", "sec_admin_session_digest")
        self.assertIn("group_name = module.eventbridge.schedule_group_name", sch)
        self.assertIn('default     = "rate(1 hour)"', TF)
        self.assertIn("maximum_retry_attempts       = 0", _resource("aws_lambda_function_event_invoke_config",
                                                                     "sec_admin_session_digest"))
        self.assertIn("retention_in_days = 365", _resource("aws_cloudwatch_log_group", "sec_admin_session_digest"))
        alarm = _resource("aws_cloudwatch_metric_alarm", "sec_admin_session_digest_errors")
        self.assertIn("${local.runbook_suffix.incident}\"", alarm)
        self.assertIn("alarm_actions       = [aws_sns_topic.alerts.arn]", alarm)

    def test_no_account_id_in_the_file(self):
        self.assertNotRegex(TF, r"(?<!\d)\d{12}(?!\d)")


NAMES = chk.digest_names("dev")


def _fn(**over):
    fn = {"State": "Active", "LastUpdateStatus": "Successful", "Environment": {"Variables": {
        k: "x" for k in chk.DIGEST_ENV_KEYS}}}
    fn["Environment"]["Variables"]["ACTIVITY_REGIONS"] = "us-east-1,us-west-1"
    fn.update(over)
    return fn


SCHEDULE = {"State": "ENABLED", "Target": {"Arn": "arn:aws:lambda:us-west-1:111122223333:function:"
                                                  "aa-sec-dev-admin-session-digest"}}
LOGS = [{"logGroupName": "/aws/lambda/aa-sec-dev-admin-session-digest", "retentionInDays": 365}]


class DigestToolTest(unittest.TestCase):
    def test_names(self):
        self.assertEqual(NAMES["group"], "aa-cis-dev-acp")
        self.assertEqual(NAMES["schedule"], "aa-sec-dev-admin-session-digest-hourly")
        self.assertIn('name        = "${local.sec_digest_fn_name}-hourly"', TF)

    def test_config_ok(self):
        self.assertEqual(chk.digest_config_problems(_fn(), SCHEDULE, LOGS, NAMES), [])

    def test_config_problems(self):
        bad_env = _fn()
        bad_env["Environment"]["Variables"]["ACTIVITY_REGIONS"] = "us-west-1"
        del bad_env["Environment"]["Variables"]["STATE_KEY"]
        problems = chk.digest_config_problems(bad_env, {"State": "DISABLED", "Target": {"Arn": "x"}},
                                              [{"logGroupName": LOGS[0]["logGroupName"], "retentionInDays": 30}],
                                              NAMES)
        text = "\n".join(problems)
        for part in ("STATE_KEY", "us-east-1", "DISABLED", "target", "retention"):
            self.assertIn(part, text)
        self.assertIn("function state Pending", "\n".join(chk.digest_config_problems(
            _fn(State="Pending"), SCHEDULE, LOGS, NAMES)))

    def test_preview_problems(self):
        clean = {"preview": True, "messages": [{"subject": "[aa-sec] x", "message": "user lan.tester@… bucket b"}]}
        self.assertEqual(chk.preview_problems({"StatusCode": 200}, clean), [])
        leaky = {"preview": True, "messages": [
            {"subject": "s", "message": "role arn:aws:iam::111122223333:role/x by someone@example.org"}]}
        self.assertEqual(chk.preview_problems({"StatusCode": 200}, leaky),
                         ["digest 0 holds account id, ARN, e-mail address"])
        self.assertEqual(chk.preview_problems({"StatusCode": 200}, {"digests": 1}),
                         ["the function did not run in preview mode"])
        self.assertTrue(chk.preview_problems({"FunctionError": "Unhandled"}, {"errorMessage": "boom"})[0]
                        .startswith("function error"))


if __name__ == "__main__":
    unittest.main()
