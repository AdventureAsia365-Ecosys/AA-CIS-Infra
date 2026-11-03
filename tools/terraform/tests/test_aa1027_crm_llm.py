"""AA-1027 F4 (interim path): offline guards for the CRM AI gateway model on acc2 (modules/environment/crm_llm.tf).

1. The CRM task role's model grant is least privilege: one statement, bedrock:InvokeModel only, on the Nova Lite us.
   inference profile of this account and region plus that one foundation model in the US regions; no wildcard
   action, no other model, no global profile, no literal account id (var.account_id only).
2. The task env is the provider, the model id, the CIS catalogue prices of 'nova-lite', the region and the output cap,
   and never CRM_LLM_ROLE_ARN (acc3 is not used); crm_app.tf passes it to the CRM API container.
3. The switch is a variable (default off) that terraform.tfvars turns on for Dev.

Run: python3 -m pytest -q tools/terraform/tests/test_aa1027_crm_llm.py
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
AA365 = ROOT / "accounts" / "aa365"
# AA-1004 slice 2: the CRM stack lives in modules/environment (instantiated by accounts/aa365, which keeps tfvars).
ENV_MODULE = ROOT / "modules" / "environment"
LLM = (ENV_MODULE / "crm_llm.tf").read_text(encoding="utf-8")
APP = (ENV_MODULE / "crm_app.tf").read_text(encoding="utf-8")
TFVARS = (AA365 / "terraform.tfvars").read_text(encoding="utf-8")

PROFILE = "us.amazon.nova-lite-v1:0"
FOUNDATION = "amazon.nova-lite-v1:0"
# CIS migration 324, shared.llm_model_catalog 'nova-lite' (and AA-Partner crm-042's route row).
CATALOGUE_PRICES = ("0.077", "0.308")


def _resource(text: str, kind: str, name: str) -> str:
    m = re.search(rf'^resource "{kind}" "{name}" \{{', text, re.M)
    assert m, f"{kind}.{name} not found"
    body = text[m.end():]
    end = re.search(r"^\}", body, re.M)
    return body[: end.start()]


def _local(name: str) -> str:
    m = re.search(rf'^\s*{name}\s*=\s*"([^"]*)"', LLM, re.M)
    assert m, f"local {name} not found"
    return m.group(1)


class CrmLlmGrant(unittest.TestCase):
    def test_one_statement_invoke_model_only_on_the_task_role(self) -> None:
        body = _resource(LLM, "aws_iam_role_policy", "crm_ecs_task_llm")
        self.assertIn("role = aws_iam_role.crm_ecs_task.id", body)
        self.assertEqual(body.count("Sid "), 1)
        self.assertRegex(body, r'Action\s*=\s*"bedrock:InvokeModel"\n')
        self.assertIn("Resource = local.crm_llm_model_arns", body)
        self.assertNotIn("*", re.sub(r"#.*", "", body))

    def test_the_resources_are_the_profile_and_its_foundation_model_in_us_regions(self) -> None:
        self.assertEqual(_local("crm_llm_profile_id"), PROFILE)
        self.assertEqual(_local("crm_llm_foundation_model"), FOUNDATION)
        arns = re.search(r"crm_llm_model_arns = concat\((.*?)\n  \)", LLM, re.S)
        assert arns
        text = arns.group(1)
        self.assertIn(
            '"arn:aws:bedrock:${var.aws_region}:${var.account_id}:inference-profile/${local.crm_llm_profile_id}"', text
        )
        self.assertIn('"arn:aws:bedrock:${region}::foundation-model/${local.crm_llm_foundation_model}"', text)
        regions = re.search(r"crm_llm_profile_regions = \[([^\]]*)\]", LLM)
        assert regions
        self.assertEqual(
            sorted(r.strip().strip('"') for r in regions.group(1).split(",")),
            ["us-east-1", "us-east-2", "us-west-1", "us-west-2"],
        )
        self.assertNotIn("global.", LLM.split("locals {", 1)[1])
        self.assertIsNone(re.search(r"\b\d{12}\b", LLM), "no literal account id")


class CrmLlmEnv(unittest.TestCase):
    def test_the_env_names_the_model_and_its_catalogue_prices(self) -> None:
        env = re.search(r"crm_llm_env = local\.crm_llm_enabled \? \[(.*?)\] : \[\]", LLM, re.S)
        assert env
        names = re.findall(r'name = "([A-Z_]+)"', env.group(1))
        self.assertEqual(
            names,
            [
                "CRM_LLM_PROVIDER",
                "CRM_LLM_MODEL_ID",
                "CRM_LLM_USD_PER_MTOK_IN",
                "CRM_LLM_USD_PER_MTOK_OUT",
                "CRM_LLM_REGION",
                "CRM_LLM_MAX_TOKENS",
            ],
        )
        self.assertIn('{ name = "CRM_LLM_PROVIDER", value = "bedrock" }', env.group(1))
        self.assertNotIn("ROLE_ARN", env.group(1).replace("No CRM_LLM_ROLE_ARN", ""))
        self.assertEqual((_local("crm_llm_usd_per_mtok_in"), _local("crm_llm_usd_per_mtok_out")), CATALOGUE_PRICES)
        self.assertTrue(50 <= int(_local("crm_llm_max_tokens")) <= 4000)  # AA-Partner settings bounds

    def test_the_crm_api_container_gets_the_env(self) -> None:
        task = _resource(APP, "aws_ecs_task_definition", "crm_api")
        self.assertIn("local.crm_llm_env", task)

    def test_the_switch_defaults_off_and_is_on_for_dev(self) -> None:
        var = re.search(r'variable "crm_llm_bedrock_enabled" \{(.*?)\n\}', LLM, re.S)
        assert var
        self.assertIn("default     = false", var.group(1))
        self.assertRegex(TFVARS, r"(?m)^crm_llm_bedrock_enabled = true$")


if __name__ == "__main__":
    unittest.main()
