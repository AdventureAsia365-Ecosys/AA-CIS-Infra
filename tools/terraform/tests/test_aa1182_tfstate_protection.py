"""AA-1182 (S296): offline guards for the Terraform state bucket policy, the TripPlanner Lambda artifacts bucket policy
and the narrowed CIS ECS task role.

1. accounts/aa365/tfstate_protection.tf locks the backend bucket of versions.tf: TLS only; every S3 action but the
   bucket configuration reads denied outside the CI plan role, the CI apply role and the MFA admin; the plan role writes
   only the S3 lockfile; only the MFA admin deletes versions or changes the bucket configuration. The bucket itself is
   never a Terraform resource (it holds this root's state), and every managed piece is prevent_destroy.
2. modules/environment/tripplanner.tf: the artifacts bucket is TLS only and only its deployers write code there.
3. modules/ecs/main.tf: no Allow on "*" for S3, Secrets Manager reads, SQS, CloudWatch Logs writes or Bedrock invoke;
   the named grants sit in a customer managed policy (the role's inline policies share one 10,240-character limit and
   were already near it), so the role keeps exactly its eleven inline policies and the managed policy stays inside a
   size budget; the S3 grant is the bronze bucket plus the gold tenant backup prefix; the runtime secret list never
   names the master or migrator DSN; the S18/S19 Deny statement is untouched.

Run: python3 -m pytest -q tools/terraform/tests/test_aa1182_tfstate_protection.py
"""
import re
import unittest
from pathlib import Path

from test_secret_read_guards import _block_after, _statement  # same brace walkers, one copy

ROOT = Path(__file__).resolve().parents[3]
AA365 = ROOT / "accounts" / "aa365"
TFSTATE = (AA365 / "tfstate_protection.tf").read_text(encoding="utf-8")
VERSIONS = (AA365 / "versions.tf").read_text(encoding="utf-8")
ENV_TF = (AA365 / "environment.tf").read_text(encoding="utf-8")
ROOT_MAIN = (AA365 / "main.tf").read_text(encoding="utf-8")
TP_TF = (ROOT / "modules" / "environment" / "tripplanner.tf").read_text(encoding="utf-8")
ECS_MAIN = (ROOT / "modules" / "ecs" / "main.tf").read_text(encoding="utf-8")
ECS_VARS = (ROOT / "modules" / "ecs" / "variables.tf").read_text(encoding="utf-8")
MGMT_README = (ROOT / "accounts" / "management" / "README.md").read_text(encoding="utf-8")


def _policy_document(text: str, name: str) -> str:
    return _block_after(text, text.index(f'data "aws_iam_policy_document" "{name}"'))


def _list_after(text: str, key: str) -> str:
    """The bracket-balanced list assigned to ``key`` (first occurrence)."""
    m = re.search(rf"\b{re.escape(key)}\s*=\s*\[", text)
    assert m, f"{key} not found"
    depth = 0
    for j in range(m.end() - 1, len(text)):
        if text[j] == "[":
            depth += 1
        elif text[j] == "]":
            depth -= 1
            if depth == 0:
                return text[m.end() - 1: j + 1]
    raise AssertionError("unbalanced list")


class StateBucketPolicyTest(unittest.TestCase):
    def setUp(self):
        self.doc = _policy_document(TFSTATE, "tfstate")

    def test_bucket_is_the_backend_bucket(self):
        backend = re.search(r'backend "s3" \{.*?bucket\s*=\s*"([^"]+)"', VERSIONS, re.S)
        self.assertIsNotNone(backend)
        self.assertEqual(backend.group(1), "aa-cis-tfstate-005097885195")
        self.assertIn('tfstate_bucket     = "aa-cis-tfstate-${var.account_id}"', TFSTATE)

    def test_lock_lives_in_the_same_bucket(self):
        # S3 native locking writes <key>.tflock next to the state, so the bucket policy covers the lock. A DynamoDB
        # lock table would sit outside this policy.
        self.assertRegex(VERSIONS, r"use_lockfile\s*=\s*true")
        self.assertNotRegex(VERSIONS, r"(?m)^\s*dynamodb_table\s*=")

    def test_bucket_is_never_a_terraform_resource(self):
        self.assertNotRegex(TFSTATE, r'resource\s+"aws_s3_bucket"\s')

    def test_tls_only(self):
        stmt = _statement(self.doc, "DenyInsecureTransport")
        self.assertRegex(stmt, r'effect\s*=\s*"Deny"')
        self.assertIn('"s3:*"', stmt)
        self.assertIn('"aws:SecureTransport"', stmt)
        self.assertRegex(stmt, r'values\s*=\s*\["false"\]')

    def test_state_access_only_for_terraform_roles_and_admin(self):
        stmt = _statement(self.doc, "DenyStateAccessOutsideTerraform")
        self.assertRegex(stmt, r"not_actions\s*=\s*local\.tfstate_config_read_actions")
        self.assertRegex(stmt, r'test\s*=\s*"ArnNotLike"')
        self.assertIn('"aws:PrincipalArn"', stmt)
        self.assertRegex(stmt, r"values\s*=\s*local\.tfstate_terraform_principal_arns")
        principals = TFSTATE[TFSTATE.index("tfstate_terraform_principal_arns = concat("):]
        principals = principals[: principals.index("\n  )") + 4]
        for want in ("aws_iam_role.tf_plan.arn", "aws_iam_role.tf_apply.arn", "local.tfstate_admin_principal_arns"):
            with self.subTest(principal=want):
                self.assertIn(want, principals)

    def test_config_reads_never_open_object_access(self):
        reads = _list_after(TFSTATE, "tfstate_config_read_actions")
        for action in re.findall(r'"([^"]+)"', reads):
            with self.subTest(action=action):
                self.assertTrue(action.startswith("s3:Get"), action)
                self.assertNotIn("Object", action)

    def test_plan_role_writes_only_the_lockfile(self):
        stmt = _statement(self.doc, "DenyPlanRoleWritesExceptLockfile")
        self.assertIn('"s3:PutObject"', stmt)
        self.assertIn('"s3:DeleteObject"', stmt)
        self.assertRegex(stmt, r'not_resources\s*=\s*\["\$\{local\.tfstate_bucket_arn\}/\*\.tflock"\]')
        self.assertRegex(stmt, r'test\s*=\s*"ArnLike"')
        self.assertRegex(stmt, r"values\s*=\s*\[aws_iam_role\.tf_plan\.arn\]")

    def test_history_and_configuration_only_for_admin(self):
        stmt = _statement(self.doc, "DenyHistoryAndConfigChangesOutsideAdmin")
        for action in ("s3:DeleteObjectVersion", "s3:PutBucket*", "s3:DeleteBucket*", "s3:PutLifecycleConfiguration",
                       "s3:PutEncryptionConfiguration", "s3:PutReplicationConfiguration"):
            with self.subTest(action=action):
                self.assertIn(f'"{action}"', stmt)
        self.assertRegex(stmt, r"values\s*=\s*local\.tfstate_admin_principal_arns")
        admin = TFSTATE[TFSTATE.index("tfstate_admin_principal_arns = concat("):]
        admin = admin[: admin.index("\n  )") + 4]
        self.assertIn("aws_iam_role.admin.arn", admin)
        self.assertNotIn("tf_apply", admin)
        self.assertNotIn("tf_plan", admin)

    def test_admin_sso_pattern_is_the_company_permission_set_only(self):
        self.assertRegex(TFSTATE, r'default\s*=\s*\["AA-Admin"\]')
        self.assertIn("AWSReservedSSO_${p}_*", TFSTATE)
        var_block = _block_after(TFSTATE, TFSTATE.index('variable "tfstate_admin_sso_permission_sets"'))
        self.assertNotIn("AdministratorAccess", _list_after(var_block, "default"))

    def test_org_break_glass_role_is_an_admin_once_enabled(self):
        # After the move the company admin enters through OrganizationAccountAccessRole (org_access.tf); without it
        # that path could neither read state nor repair this policy. Gated so a reseller-owned role of that name is
        # never trusted before the move.
        admin = TFSTATE[TFSTATE.index("tfstate_admin_principal_arns = concat("):]
        admin = admin[: admin.index("\n  )") + 4]
        self.assertIn(
            'var.org_access_role_enabled ? ["arn:aws:iam::${var.account_id}:role/${var.org_access_role_name}"] : []',
            admin,
        )
        # Only an admin may write this policy, so the local apply that creates the role also updates it.
        self.assertIn("-target=aws_s3_bucket_policy.tfstate", MGMT_README)

    def test_versioning_and_public_access_block_are_imported_not_created(self):
        for res in ("aws_s3_bucket_versioning", "aws_s3_bucket_public_access_block"):
            with self.subTest(resource=res):
                self.assertRegex(TFSTATE, rf"import\s*\{{\s*to\s*=\s*{res}\.tfstate")
        self.assertRegex(TFSTATE, r'status\s*=\s*"Enabled"')
        for flag in ("block_public_acls", "block_public_policy", "ignore_public_acls", "restrict_public_buckets"):
            with self.subTest(flag=flag):
                self.assertRegex(TFSTATE, rf"{flag}\s*=\s*true")

    def test_every_managed_piece_is_prevent_destroy(self):
        for res in ("aws_s3_bucket_versioning", "aws_s3_bucket_public_access_block", "aws_s3_bucket_policy"):
            with self.subTest(resource=res):
                block = _block_after(TFSTATE, TFSTATE.index(f'resource "{res}" "tfstate"'))
                self.assertRegex(block, r"prevent_destroy\s*=\s*true")


class ArtifactsBucketPolicyTest(unittest.TestCase):
    def setUp(self):
        self.doc = _policy_document(TP_TF, "tripplanner_artifacts")

    def test_tls_only(self):
        stmt = _statement(self.doc, "DenyInsecureTransport")
        self.assertIn('"aws:SecureTransport"', stmt)

    def test_only_deployers_write_code(self):
        stmt = _statement(self.doc, "DenyCodeWritesOutsideDeployers")
        for action in ("s3:PutObject", "s3:DeleteObject", "s3:DeleteObjectVersion"):
            with self.subTest(action=action):
                self.assertIn(f'"{action}"', stmt)
        self.assertRegex(stmt, r'test\s*=\s*"ArnNotLike"')
        self.assertIn("aws_iam_role.tripplanner_app_deploy.arn", stmt)
        self.assertIn("var.lambda_artifacts_writer_role_arns", stmt)

    def test_policy_is_attached(self):
        self.assertRegex(TP_TF, r'resource "aws_s3_bucket_policy" "tripplanner_artifacts"')

    def test_root_passes_apply_and_admin_roles(self):
        writers = _list_after(ENV_TF, "lambda_artifacts_writer_role_arns")
        self.assertIn("local.tf_apply_role_name", writers)
        self.assertIn("var.identity_breakglass_admin_role_name", writers)


TASK_ROLE_INLINE_POLICIES = {
    # modules/ecs/main.tf
    "ecs_task_policy", "ecs_task_exec_logging", "ecs_task_tripplanner_custom_domain", "ecs_task_infra_status_readonly",
    # accounts/aa365
    "cis_ecs_task_workforce_directory", "cis_ecs_task_ses_send", "cis_ecs_task_partner_pool_read",
    "ecs_read_compliance_evidence", "ecs_assume_bedrock_invoker", "cis_ecs_task_alert_recipients",
    "ecs_assume_cost_explorer_reader",
}

# Offline render of the eleven inline policies on main 27/11/2026 (lane notes, docs/implementation-notes/AA-1182.md):
# about 9.8k of the 10,240 characters IAM allows for all inline policies of a role together, once the old "*" statement
# is gone. Placeholder values below have the live lengths (12-digit account, real bucket and secret name shapes).
MANAGED_POLICY_LIMIT = 6144
MANAGED_POLICY_BUDGET = 4500  # leaves room for about fifteen more secret names or providers before the limit


def _render_data_access_policy() -> str:
    """Minified JSON of ecs_task_data_access with the module defaults and live-length placeholders."""
    import json

    account, region = "123456789012", "us-west-1"
    names = re.findall(r'"([a-z0-9-]+)",\s*#', _block_after(ECS_VARS, ECS_VARS.index('variable "runtime_secret_names"')))
    prov_block = _block_after(ECS_VARS, ECS_VARS.index('variable "bedrock_invoke_providers"'))
    providers = re.findall(r'"([a-z0-9-]+)"', _list_after(prov_block, "default"))
    sm = f"arn:aws:secretsmanager:{region}:{account}:secret:"
    bronze, gold = f"aa-cis-bronze-{account}", f"aa-cis-gold-{account}"
    supply = f"aa-booking-dev-supply-media-{account}"
    statements = [
        {"Sid": "CisBronzeObjectReadWrite", "Effect": "Allow", "Action": ["s3:PutObject", "s3:GetObject"],
         "Resource": f"arn:aws:s3:::{bronze}/*"},
        {"Sid": "CisGoldTenantBackupReadWrite", "Effect": "Allow", "Action": ["s3:PutObject", "s3:GetObject"],
         "Resource": f"arn:aws:s3:::{gold}/exports/tenants/*"},
        {"Sid": "CisBucketList", "Effect": "Allow", "Action": "s3:ListBucket",
         "Resource": [f"arn:aws:s3:::{bronze}", f"arn:aws:s3:::{gold}"]},
        {"Sid": "ReadCisRuntimeSecrets", "Effect": "Allow", "Action": "secretsmanager:GetSecretValue",
         "Resource": [f"{sm}aa-cis/dev/{n}-??????" for n in names]
         + [f"{sm}aa-llm/dev/*", f"{sm}acp/cms/*", f"{sm}acp/social/*"]},
        {"Sid": "BedrockInvokeOwnAccountModels", "Effect": "Allow",
         "Action": ["bedrock:InvokeModelWithResponseStream", "bedrock:InvokeModel"],
         "Resource": [a for p in providers for a in (f"arn:aws:bedrock:*::foundation-model/{p}.*",
                                                    f"arn:aws:bedrock:*:{account}:inference-profile/*.{p}.*")]},
        {"Sid": "ReadBookingSupplyMedia", "Effect": "Allow", "Action": "s3:GetObject",
         "Resource": f"arn:aws:s3:::{supply}/*"},
    ]
    return json.dumps({"Version": "2012-10-17", "Statement": statements}, separators=(",", ":"))


class CisTaskRoleNarrowTest(unittest.TestCase):
    def setUp(self):
        start = ECS_MAIN.index('resource "aws_iam_role_policy" "ecs_task_policy"')
        self.policy = _block_after(ECS_MAIN, start)
        self.managed = _policy_document(ECS_MAIN, "ecs_task_data_access")

    def _allow_statements(self):
        """(actions text, resource text) of every Allow object in the policy's jsonencode body."""
        out = []
        for m in re.finditer(r'Effect\s*=\s*"Allow"', self.policy):
            block = _block_after(self.policy, self.policy.rindex("{", 0, m.start()))
            out.append(block)
        return out

    def test_no_wildcard_resource_for_data_or_model_actions(self):
        risky = ("s3:", "secretsmanager:GetSecretValue", "sqs:", "logs:", "bedrock:InvokeModel")
        for block in self._allow_statements():
            if re.search(r'Resource\s*=\s*"\*"', block):
                for action in risky:
                    with self.subTest(block=block[:60], action=action):
                        self.assertNotIn(f'"{action}', block)
        self.assertNotRegex(self.managed, r'resources\s*=\s*\["\*"\]')

    def test_sqs_and_log_writes_are_gone(self):
        self.assertNotIn('"sqs:', self.policy)
        self.assertNotIn('"logs:CreateLogGroup"', self.policy)
        self.assertNotIn('"logs:PutLogEvents"', self.policy)

    def test_named_grants_are_a_managed_policy_attached_before_the_narrowing(self):
        self.assertRegex(ECS_MAIN, r'resource "aws_iam_policy" "ecs_task_data_access"')
        attach = _block_after(ECS_MAIN, ECS_MAIN.index('resource "aws_iam_role_policy_attachment" "ecs_task_data_access"'))
        self.assertIn("aws_iam_role.ecs_task.name", attach)
        self.assertIn("aws_iam_policy.ecs_task_data_access.arn", attach)
        # The inline policy narrows only once the attachment exists (a CI apply before the bootstrap apply fails on
        # CreatePolicy and leaves the old grants in place).
        self.assertRegex(self.policy, r"depends_on\s*=\s*\[aws_iam_role_policy_attachment\.ecs_task_data_access\]")
        for sid in ("CisBronzeObjectReadWrite", "ReadCisRuntimeSecrets", "BedrockInvokeOwnAccountModels"):
            with self.subTest(sid=sid):
                self.assertNotIn(f'"{sid}"', self.policy)

    def test_task_role_keeps_its_eleven_inline_policies(self):
        # Every inline policy of a role shares one 10,240-character limit and these eleven already render to about
        # 9.8k: a new grant for the CIS task role goes into ecs_task_data_access (or another managed policy), never
        # into a new inline policy. A plan does not check the limit; PutRolePolicy fails at apply.
        found = set()
        for path in [ROOT / "modules" / "ecs" / "main.tf", *sorted(AA365.glob("*.tf"))]:
            text = path.read_text(encoding="utf-8")
            for m in re.finditer(r'resource "aws_iam_role_policy" "([^"]+)"', text):
                block = _block_after(text, m.start())
                if re.search(r"role\s*=\s*(aws_iam_role\.ecs_task\.(id|name)|module\.ecs\.task_role_name)\b", block):
                    found.add(m.group(1))
        self.assertEqual(found, TASK_ROLE_INLINE_POLICIES)

    def test_managed_policy_stays_inside_its_size_budget(self):
        size = len(_render_data_access_policy())
        self.assertLess(MANAGED_POLICY_BUDGET, MANAGED_POLICY_LIMIT)
        self.assertLessEqual(size, MANAGED_POLICY_BUDGET, f"ecs_task_data_access renders to about {size} characters")

    def test_render_covers_every_statement(self):
        rendered = _render_data_access_policy()
        for sid in re.findall(r'sid\s*=\s*"([A-Za-z]+)"', self.managed):
            with self.subTest(sid=sid):
                self.assertIn(f'"Sid":"{sid}"', rendered)

    def test_s3_grant_is_bronze_and_the_gold_backup_prefix_only(self):
        bronze = _statement(self.managed, "CisBronzeObjectReadWrite")
        self.assertIn('"arn:aws:s3:::${var.bronze_bucket_name}/*"', bronze)
        gold = _statement(self.managed, "CisGoldTenantBackupReadWrite")
        self.assertIn('"arn:aws:s3:::${var.gold_bucket_name}/${local.cis_gold_backup_prefix}*"', gold)
        self.assertRegex(ECS_MAIN, r'cis_gold_backup_prefix\s*=\s*"exports/tenants/"')
        self.assertNotIn('"arn:aws:s3:::${var.gold_bucket_name}/*"', ECS_MAIN)
        listing = _statement(self.managed, "CisBucketList")
        self.assertIn('"s3:ListBucket"', listing)
        self.assertEqual(sorted(re.findall(r'"arn:aws:s3:::([^"]+)"', listing)),
                         ["${var.bronze_bucket_name}", "${var.gold_bucket_name}"])
        supply = _statement(self.managed, "ReadBookingSupplyMedia")
        self.assertIn('actions   = ["s3:GetObject"]', supply)
        self.assertIn("gold_bucket_name                 = module.s3.gold_bucket_name", ROOT_MAIN)

    def test_secret_reads_are_named(self):
        stmt = _statement(self.managed, "ReadCisRuntimeSecrets")
        self.assertIn("local.cis_runtime_secret_arns", stmt)
        var_block = _block_after(ECS_VARS, ECS_VARS.index('variable "runtime_secret_names"'))
        names = re.findall(r'"([a-z0-9-]+)",\s*#', var_block)
        self.assertIn("rds-app-user", names)
        self.assertNotIn("rds", names)
        self.assertNotIn("db-migrator", names)
        self.assertFalse(any(n.startswith("e2e") for n in names), names)
        arns = ECS_MAIN[ECS_MAIN.index("cis_runtime_secret_arns = concat("):]
        arns = arns[: arns.index("\n  )") + 4]
        for want in ("secret:aa-llm/${var.environment}/*", "secret:acp/cms/*", "secret:acp/social/*",
                     "${var.project}/${var.environment}/${n}-??????"):
            with self.subTest(arn=want):
                self.assertIn(want, arns)

    def test_bedrock_invoke_is_per_provider(self):
        stmt = _statement(self.managed, "BedrockInvokeOwnAccountModels")
        self.assertIn("local.cis_bedrock_invoke_arns", stmt)
        self.assertIn('"arn:aws:bedrock:*::foundation-model/${p}.*"', ECS_MAIN)
        self.assertIn("inference-profile/*.${p}.*", ECS_MAIN)

    def test_master_deny_is_kept(self):
        deny = _statement(self.policy, "DenyMasterAndOtherAppSecrets")
        self.assertIn("rds-??????", deny)
        self.assertIn("db-migrator-??????", deny)


if __name__ == "__main__":
    unittest.main()
