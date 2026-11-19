"""AA-1138 (S285): offline guards for the CRM's Claude route entry on acc1 (modules/environment/crm_llm_acc1.tf and the
trust statement of accounts/acc1-bedrock/main.tf).

1. The CRM task role's grant is least privilege: one statement, sts:AssumeRole only, on exactly acc1's
   AA1-Bedrock-Invoker built from var.bedrock_acct_payer (no literal account ID in the module file).
2. The switch is off by default, needs the CRM's Bedrock switch and the acc1 ID, and terraform.tfvars turns it on.
3. The task env is CRM_LLM_ACC1_ROLE_ARN and CRM_LLM_ACC1_EXTERNAL_ID only, and crm_app.tf passes it to the CRM API.
4. The acc1 trust names the CRM task role (its name as crm_data.tf builds it for dev) with the CRM's own ExternalId,
   equal to the module's; the CIS statement keeps its own ExternalId; the trust inventory acknowledges both roles.

Run: python3 -m pytest -q tools/terraform/tests/test_aa1138_crm_acc1.py
"""
import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
ENV_MODULE = ROOT / "modules" / "environment"
ACC1 = (ROOT / "accounts" / "acc1-bedrock" / "main.tf").read_text(encoding="utf-8")
GRANT = (ENV_MODULE / "crm_llm_acc1.tf").read_text(encoding="utf-8")
APP = (ENV_MODULE / "crm_app.tf").read_text(encoding="utf-8")
DATA = (ENV_MODULE / "crm_data.tf").read_text(encoding="utf-8")
TFVARS = (ROOT / "accounts" / "aa365" / "terraform.tfvars").read_text(encoding="utf-8")
ALLOW = json.loads((ROOT / "tools" / "terraform" / "iam_trust_allowlist.json").read_text(encoding="utf-8"))


def _block(text: str, opener: str) -> str:
    start = text.index(opener)
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start : i + 1]
    raise AssertionError(f"unclosed block: {opener}")


def _local(text: str, name: str) -> str:
    m = re.search(rf'^\s*{name}\s*=\s*"([^"]*)"', text, re.M)
    assert m, f"local {name} not found"
    return m.group(1)


class CrmAcc1Grant(unittest.TestCase):
    def test_one_assume_role_statement_on_the_acc1_invoker_only(self) -> None:
        body = _block(GRANT, 'resource "aws_iam_role_policy" "crm_ecs_task_llm_acc1" {')
        self.assertIn("count = local.crm_llm_acc1_on ? 1 : 0", body)
        self.assertIn("role = aws_iam_role.crm_ecs_task.id", body)
        self.assertEqual(body.count("Sid "), 1)
        self.assertRegex(body, r'Action\s*=\s*"sts:AssumeRole"\n')
        self.assertIn("Resource = local.crm_llm_acc1_role_arn", body)
        self.assertNotIn("*", re.sub(r"#.*", "", body))
        self.assertEqual(
            _local(GRANT, "crm_llm_acc1_role_arn"), "arn:aws:iam::${var.bedrock_acct_payer}:role/AA1-Bedrock-Invoker"
        )
        self.assertIsNone(re.search(r"(?<![0-9])\d{12}(?![0-9])", GRANT), "no literal account id")

    def test_the_switch_needs_bedrock_and_the_acc1_id_and_is_on_for_dev(self) -> None:
        var = _block(GRANT, 'variable "crm_llm_acc1_enabled" {')
        self.assertIn("default     = false", var)
        self.assertIn(
            'crm_llm_acc1_on = local.crm_llm_enabled && var.crm_llm_acc1_enabled && var.bedrock_acct_payer != ""', GRANT
        )
        payer = _block(GRANT, 'variable "bedrock_acct_payer" {')
        self.assertIn('default     = ""', payer)
        self.assertRegex(TFVARS, r"(?m)^crm_llm_acc1_enabled = true$")


class CrmAcc1Env(unittest.TestCase):
    def test_the_env_is_the_role_and_its_external_id(self) -> None:
        env = re.search(r"crm_llm_acc1_env = local\.crm_llm_acc1_on \? \[(.*?)\] : \[\]", GRANT, re.S)
        assert env
        self.assertEqual(
            re.findall(r'name = "([A-Z0-9_]+)"', env.group(1)), ["CRM_LLM_ACC1_ROLE_ARN", "CRM_LLM_ACC1_EXTERNAL_ID"]
        )
        self.assertIn("value = local.crm_llm_acc1_role_arn", env.group(1))
        self.assertIn("value = local.crm_llm_acc1_external_id", env.group(1))

    def test_the_crm_api_container_gets_the_env(self) -> None:
        task = _block(APP, 'resource "aws_ecs_task_definition" "crm_api" {')
        self.assertIn("local.crm_llm_acc1_env", task)


class Acc1Trust(unittest.TestCase):
    def _statement(self, sid: str) -> str:
        m = re.search(rf'\{{\s*Sid\s*=\s*"{sid}"(.*?)\n      \}}', ACC1, re.S)
        assert m, sid
        return m.group(1)

    def test_the_crm_statement_names_the_crm_task_role_with_its_own_external_id(self) -> None:
        crm = self._statement("AllowAcc2CrmEcsTaskRoleAssume")
        self.assertIn('Action    = "sts:AssumeRole"', crm)
        self.assertIn('"sts:ExternalId" = local.crm_external_id', crm)
        role = re.search(r'Principal = \{ AWS = "arn:aws:iam::\d{12}:role/([^"]+)" \}', crm)
        assert role
        # crm_data.tf: "${local.crm_name_prefix}-ecs-task-role", crm_name_prefix = "aa-crm-${var.environment}" (dev)
        self.assertIn('crm_task_role_name      = "${local.crm_name_prefix}-ecs-task-role"', DATA)
        self.assertEqual(role.group(1), "aa-crm-dev-ecs-task-role")

    def test_the_external_ids_match_and_differ_from_the_cis_one(self) -> None:
        self.assertEqual(_local(ACC1, "crm_external_id"), _local(GRANT, "crm_llm_acc1_external_id"))
        self.assertNotEqual(_local(ACC1, "crm_external_id"), _local(ACC1, "external_id"))
        cis = self._statement("AllowAcc2ECSTaskRoleAssume")
        self.assertIn('"sts:ExternalId" = local.external_id', cis)

    def test_the_trust_inventory_acknowledges_both_task_roles(self) -> None:
        [entry] = [a for a in ALLOW["acknowledged"] if a["match"] == "accounts/acc1-bedrock:aws_iam_role.bedrock_invoker"]
        self.assertEqual(
            sorted(entry["principal"]),
            ["arn:*:iam::*:role/aa-cis-dev-ecs-task-role", "arn:*:iam::*:role/aa-crm-dev-ecs-task-role"],
        )


if __name__ == "__main__":
    unittest.main()
