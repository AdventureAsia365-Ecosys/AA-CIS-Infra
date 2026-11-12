"""AA-1092 (S278 system audit M19): offline guards for the TripPlanner tenant assertion key's infra.

1. Secret tripplanner/<env>/tenant-assertion-key is a SHELL: no secret_version, no data source, so Terraform and the
   plan role never read the key, and its ARN is not on the plan refresh list (local.tf_plan_secret_arns).
2. The browse + assembly execution role reads it (one statement, that ARN only); the jobs role does not.
3. The web task maps only its "current" field into TP_TENANT_ASSERTION_KEY, and the web execution role's secret list
   carries the ARN (a task whose secret it cannot read fails to start).
4. The fill / rotate tool exists and names the same secret.

Run: python3 -m pytest -q tools/terraform/tests/test_aa1092_tenant_assertion_key.py
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
AA365 = ROOT / "accounts" / "aa365"
ENV = ROOT / "modules" / "environment"
TP = (ENV / "tripplanner.tf").read_text(encoding="utf-8")
TP_JOBS = (ENV / "tripplanner_jobs.tf").read_text(encoding="utf-8")
TP_WEB = (ENV / "tripplanner_web.tf").read_text(encoding="utf-8")
CICD_SPLIT = (AA365 / "cicd_split.tf").read_text(encoding="utf-8")
TOOL = (ROOT / "tools" / "identity" / "tripplanner_assertion_key.py").read_text(encoding="utf-8")

SECRET = "aws_secretsmanager_secret.tripplanner_tenant_assertion_key"


def _block(text: str, header: str) -> str:
    start = text.index(header)
    i = text.index("{", start)
    depth = 0
    for j in range(i, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[i: j + 1]
    raise AssertionError(f"unbalanced block after {header}")


def _all_tf() -> str:
    return "\n".join(f.read_text(encoding="utf-8") for d in (AA365, ROOT / "modules") for f in sorted(d.rglob("*.tf")))


class SecretShell(unittest.TestCase):
    def test_named_by_environment_and_restricted(self) -> None:
        block = _block(TP, 'resource "aws_secretsmanager_secret" "tripplanner_tenant_assertion_key"')
        self.assertIn('name                    = "tripplanner/${var.environment}/tenant-assertion-key"', block)
        self.assertIn('DataClassification = "restricted"', block)

    def test_no_version_no_data_source_not_refreshed_by_terraform(self) -> None:
        tf = _all_tf()
        self.assertNotRegex(tf, r'aws_secretsmanager_secret_version"\s+"tripplanner_tenant_assertion_key"')
        self.assertNotRegex(tf, r'data\s+"aws_secretsmanager_secret_version"[^{]*tenant_assertion')
        plan_list = re.search(r"tf_plan_secret_arns = concat\((.*?)\n  \)", CICD_SPLIT, re.S).group(1)
        self.assertNotIn("tenant_assertion", plan_list)


class Readers(unittest.TestCase):
    def test_lambda_role_reads_only_this_arn_in_its_statement(self) -> None:
        m = re.search(r'Sid\s*=\s*"ReadTenantAssertionKeySecret"(.*?)\}', TP, re.S)
        self.assertIsNotNone(m)
        self.assertIn('Action   = ["secretsmanager:GetSecretValue"]', m.group(1))
        self.assertIn(f"Resource = [{SECRET}.arn]", m.group(1))
        policy = _block(TP, 'resource "aws_iam_role_policy" "tripplanner_lambda_permissions"')
        self.assertIn("ReadTenantAssertionKeySecret", policy)

    def test_jobs_role_does_not_read_it(self) -> None:
        self.assertNotIn("tenant_assertion", TP_JOBS)

    def test_web_task_maps_only_the_current_field(self) -> None:
        self.assertIn(
            '{ name = "TP_TENANT_ASSERTION_KEY", valueFrom = "${' + SECRET + '.arn}:current::" }', TP_WEB)
        arns = re.search(r"tp_web_secret_arns = concat\((.*?)\n  \)", TP_WEB, re.S).group(1)
        self.assertIn(f"{SECRET}.arn", arns)


class Tool(unittest.TestCase):
    def test_tool_names_the_same_secret(self) -> None:
        self.assertIn('SECRET = "tripplanner/{env}/tenant-assertion-key"', TOOL)


if __name__ == "__main__":
    unittest.main()
