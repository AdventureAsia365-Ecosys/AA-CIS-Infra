"""AA-1182 (S297): offline guards for the RDS-managed master password.

1. modules/rds: the instance has manage_master_user_password = true and no password argument (the two conflict, and
   a password in config would put a value back into Terraform); password stays in ignore_changes so the switch plans as
   one in-place attribute; the managed secret rotates on an explicit schedule (variable, default 180 days, the RDS
   default is 7) without a second rotation at apply time.
2. No db_password variable in the module or the aa365 root, and no workflow reads the GitHub copy TF_VAR_DB_PASSWORD.
3. The old master DSN secret is not a data source any more, so deleting it can never break a plan.
4. The instance itself is never replaced by this change: identifier, engine, storage encryption, deletion protection and
   the final snapshot stay as they are.
5. Review S297: no [0] index on master_user_secret outside a count gate. Provider 6.69.1 keeps the empty list of the
   state in the plan that turns management on, so a bare [0] fails that plan ("Invalid index"; reproduced offline
   with the pinned provider and a crafted state). The rotation is count-gated (created by the second apply), the
   output is a splat, and the migrator task role reads the managed secret from the first apply on through a
   plan-time grant (rds!db-* + the instance tag), the exact ARN joining through compact() from the second apply on.

Run: python3 -m pytest -q tools/terraform/tests/test_aa1182_rds_managed_master.py
"""
import re
import unittest
from pathlib import Path

from test_secret_read_guards import _block_after

ROOT = Path(__file__).resolve().parents[3]
RDS_MAIN = (ROOT / "modules" / "rds" / "main.tf").read_text(encoding="utf-8")
RDS_VARS = (ROOT / "modules" / "rds" / "variables.tf").read_text(encoding="utf-8")
RDS_OUT = (ROOT / "modules" / "rds" / "outputs.tf").read_text(encoding="utf-8")
SECRETS_MAIN = (ROOT / "modules" / "secrets" / "main.tf").read_text(encoding="utf-8")
SECRETS_OUT = (ROOT / "modules" / "secrets" / "outputs.tf").read_text(encoding="utf-8")
AA365 = ROOT / "accounts" / "aa365"
MIGRATOR = (AA365 / "db_migrator.tf").read_text(encoding="utf-8")
WORKFLOWS = ROOT / ".github" / "workflows"


def _code(text: str) -> str:
    """HCL without # comments (a comment may name what the code must not contain)."""
    return "\n".join(line.split("#", 1)[0] for line in text.splitlines())


def _resource(text: str, kind: str, name: str) -> str:
    return _block_after(text, text.index(f'resource "{kind}" "{name}"'))


INSTANCE = _code(_resource(RDS_MAIN, "aws_db_instance", "main"))


class ManagedMasterPasswordTest(unittest.TestCase):
    def test_instance_lets_rds_manage_the_master_password(self):
        self.assertRegex(INSTANCE, r"\n\s*manage_master_user_password\s*=\s*true\s*\n")
        self.assertNotRegex(INSTANCE, r"\n\s*password\s*=")
        self.assertNotRegex(INSTANCE, r"\n\s*password_wo")
        self.assertNotIn("master_user_secret_kms_key_id", INSTANCE)   # the aws/secretsmanager key: no KMS cost
        self.assertRegex(INSTANCE, r"ignore_changes\s*=\s*\[password\]")

    def test_the_instance_is_not_replaced(self):
        for line in ('identifier        = "${local.name_prefix}-db"', 'engine            = "postgres"',
                     "storage_encrypted     = true", "deletion_protection = true", "skip_final_snapshot       = false",
                     "db_name  = var.db_name", "username = var.db_username"):
            self.assertIn(line, INSTANCE)

    def test_managed_secret_rotates_every_180_days_without_an_extra_rotation(self):
        rotation = _code(_resource(RDS_MAIN, "aws_secretsmanager_secret_rotation", "master"))
        self.assertIn("count = length(aws_db_instance.main.master_user_secret)", rotation)
        self.assertIn("secret_id          = aws_db_instance.main.master_user_secret[0].secret_arn", rotation)
        self.assertIn("rotate_immediately = false", rotation)
        self.assertNotIn("rotation_lambda_arn", rotation)              # RDS owns the rotation of a managed secret
        self.assertIn("automatically_after_days = var.master_password_rotation_days", rotation)
        var = _block_after(RDS_VARS, RDS_VARS.index('variable "master_password_rotation_days"'))
        self.assertRegex(var, r"default\s*=\s*180\b")
        self.assertIn("validation", var)
        self.assertIn('output "master_user_secret_arn"', RDS_OUT)
        self.assertIn("one(aws_db_instance.main.master_user_secret[*].secret_arn)", RDS_OUT)

    def test_no_bare_index_on_the_managed_secret_outside_the_count_gate(self):
        """The first plan sees master_user_secret = [] (provider 6.69.1): a [0] outside the gated rotation fails it."""
        self.assertNotIn("master_user_secret[0]", _code(RDS_OUT))
        rotation = _resource(RDS_MAIN, "aws_secretsmanager_secret_rotation", "master")
        outside = _code(RDS_MAIN.replace(rotation, ""))
        self.assertNotIn("master_user_secret[0]", outside)
        for path in sorted(AA365.glob("*.tf")):
            with self.subTest(path=path.name):
                self.assertNotIn("master_user_secret[0]", _code(path.read_text(encoding="utf-8")))

    def test_migrator_reads_the_managed_secret_from_the_first_apply_on(self):
        code = _code(MIGRATOR)
        self.assertIn("db_migrate_task_secret_arns = compact([", code)   # the exact ARN is null in the first apply
        grant = code.split('Sid      = "ReadManagedMasterSecret"', 1)[1].split('Sid      = ', 1)[0]
        self.assertIn('Action   = ["secretsmanager:GetSecretValue"]', grant)
        self.assertIn('Resource = "${local.secret_arn_prefix}rds!db-*"', grant)
        self.assertIn('StringEquals = { "secretsmanager:ResourceTag/aws:rds:primaryDBInstanceArn" = module.rds.db_arn }',
                      grant)

    def test_no_password_variable_anywhere(self):
        self.assertNotIn('variable "db_password"', RDS_VARS)
        for path in sorted(AA365.glob("*.tf")):
            code = _code(path.read_text(encoding="utf-8"))
            with self.subTest(path=path.name):
                self.assertNotIn('variable "db_password"', code)
                self.assertNotRegex(code, r"\bvar\.db_password\b")
                self.assertNotRegex(code, r"\bdb_password\s*=")

    def test_no_workflow_reads_the_ci_copy_of_the_master_password(self):
        for path in sorted(WORKFLOWS.glob("*.yml")):
            text = path.read_text(encoding="utf-8")
            with self.subTest(path=path.name):
                self.assertNotIn("TF_VAR_DB_PASSWORD", text)
                self.assertNotRegex(text, r"TF_VAR_db_password\s*:")

    def test_old_master_dsn_secret_is_not_looked_up(self):
        self.assertNotRegex(_code(SECRETS_MAIN), r'data\s+"aws_secretsmanager_secret"\s+"rds"')
        self.assertNotIn('output "rds_secret_arn"', SECRETS_OUT)
        for path in sorted(AA365.glob("*.tf")):
            with self.subTest(path=path.name):
                self.assertNotRegex(_code(path.read_text(encoding="utf-8")), r"module\.secrets\.rds_secret_arn")


if __name__ == "__main__":
    unittest.main()
