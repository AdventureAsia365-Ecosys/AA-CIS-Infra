"""AA-1182 (S296): offline guards for the Terraform state bucket policy, the TripPlanner Lambda artifacts bucket policy
and the narrowed CIS ECS task role.

1. accounts/aa365/tfstate_protection.tf locks the backend bucket of versions.tf: TLS only; every S3 action but the
   bucket configuration reads denied outside the CI plan role, the CI apply role and the MFA admin; the plan role writes
   only the S3 lockfile; only the MFA admin deletes versions or changes the bucket configuration. The bucket itself is
   never a Terraform resource (it holds this root's state), and every managed piece is prevent_destroy.
2. modules/environment/tripplanner.tf: the artifacts bucket is TLS only and only its deployers write code there.
3. modules/ecs/main.tf: no Allow on "*" for S3, Secrets Manager reads, SQS, CloudWatch Logs writes or Bedrock invoke;
   the S3 grant names the bronze and gold buckets only; the runtime secret list never names the master or migrator
   DSN; the S18/S19 Deny statement is untouched.

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


class CisTaskRoleNarrowTest(unittest.TestCase):
    def setUp(self):
        start = ECS_MAIN.index('resource "aws_iam_role_policy" "ecs_task_policy"')
        self.policy = _block_after(ECS_MAIN, start)

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

    def test_sqs_and_log_writes_are_gone(self):
        self.assertNotIn('"sqs:', self.policy)
        self.assertNotIn('"logs:CreateLogGroup"', self.policy)
        self.assertNotIn('"logs:PutLogEvents"', self.policy)

    def test_s3_grant_is_bronze_and_gold_only(self):
        self.assertRegex(ECS_MAIN, r"cis_rw_buckets\s*=\s*\[var\.bronze_bucket_name, var\.gold_bucket_name\]")
        for sid in ("CisBucketObjectReadWrite", "CisBucketList"):
            with self.subTest(sid=sid):
                self.assertIn("local.cis_rw_buckets", _statement(self.policy, sid))
        self.assertIn("gold_bucket_name                 = module.s3.gold_bucket_name", ROOT_MAIN)

    def test_secret_reads_are_named(self):
        stmt = _statement(self.policy, "ReadCisRuntimeSecrets")
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
        stmt = _statement(self.policy, "BedrockInvokeOwnAccountModels")
        self.assertIn("local.cis_bedrock_invoke_arns", stmt)
        self.assertIn('"arn:aws:bedrock:*::foundation-model/${p}.*"', ECS_MAIN)
        self.assertIn("inference-profile/*.${p}.*", ECS_MAIN)

    def test_master_deny_is_kept(self):
        deny = _statement(self.policy, "DenyMasterAndOtherAppSecrets")
        self.assertIn("rds-??????", deny)
        self.assertIn("db-migrator-??????", deny)


if __name__ == "__main__":
    unittest.main()
