"""AA-873 (S261, architecture review F1 + F2): offline guards for who may read secret values.

1. The CIS ECS task role (modules/ecs) keeps its explicit GetSecretValue Deny on the master / migrator DSNs and on
   every prefix another owner holds (booking/, tripplanner/, crm/, aa-crm/, aa-ecosys/, aa-identity/), and never
   denies a prefix the CIS code reads (aa-cis/<env>/*, acp/*, aa-llm/*).
2. The Terraform apply boundary (cicd_split.tf) denies GetSecretValue on everything except local.tf_plan_secret_arns,
   the same list the plan role may read, and that list names the secret of every secret-version resource and
   secret-version data source of the aa365 root (a version missing there would fail plan and apply on refresh).
3. The aa-agent GitHub App key and the Linear key carry a resource policy that denies the value calls to every
   principal except the MFA admin role, and Terraform only references them (data source), never creates them.

Run: python3 -m pytest -q tools/terraform/tests/test_secret_read_guards.py
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
AA365 = ROOT / "accounts" / "aa365"
ECS_MAIN = (ROOT / "modules" / "ecs" / "main.tf").read_text(encoding="utf-8")
CICD_SPLIT = (AA365 / "cicd_split.tf").read_text(encoding="utf-8")
OPS_GUARD = (AA365 / "ops_secret_guard.tf").read_text(encoding="utf-8")
IDENTITY_ALERTS = (AA365 / "identity_alerts.tf").read_text(encoding="utf-8")


def _block_after(text: str, start: int) -> str:
    """Text of the brace-balanced block whose opening brace is the first one at or after ``start``."""
    i = text.index("{", start)
    depth = 0
    for j in range(i, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[i: j + 1]
    raise AssertionError("unbalanced block")


def _bracket_after(text: str, start: int) -> str:
    """Text of the bracket- or paren-balanced expression that opens at or after ``start``."""
    m = re.compile(r"[\[(]").search(text, start)
    assert m, "no list/call after position"
    openc = m.group(0)
    closec = "]" if openc == "[" else ")"
    depth = 0
    for j in range(m.start(), len(text)):
        if text[j] == openc:
            depth += 1
        elif text[j] == closec:
            depth -= 1
            if depth == 0:
                return text[m.start(): j + 1]
    raise AssertionError("unbalanced expression")


def _statement(text: str, sid: str) -> str:
    """The HCL statement block (or jsonencode object) carrying ``sid``."""
    m = re.search(rf'[Ss]id\s*=\s*"{sid}"', text)
    assert m, f"statement {sid} not found"
    # Walk back to the opening brace of the enclosing block.
    depth = 0
    for i in range(m.start(), -1, -1):
        if text[i] == "}":
            depth += 1
        elif text[i] == "{":
            if depth == 0:
                return _block_after(text, i)
            depth -= 1
    raise AssertionError(f"no block around {sid}")


def _secret_suffixes(block: str) -> set[str]:
    """The part after ':secret:' of every Secrets Manager ARN pattern in ``block``."""
    return set(re.findall(r":secret:([^\"]+)\"", block))


TF_PLAN_SECRET_ARNS = _bracket_after(CICD_SPLIT, CICD_SPLIT.index("tf_plan_secret_arns = concat"))


class CisTaskRoleSecretDenyTest(unittest.TestCase):
    def setUp(self):
        self.deny = _statement(ECS_MAIN, "DenyMasterAndOtherAppSecrets")

    def test_is_a_deny_on_get_secret_value(self):
        self.assertRegex(self.deny, r'Effect\s*=\s*"Deny"')
        self.assertIn('"secretsmanager:GetSecretValue"', self.deny)

    def test_denies_master_migrator_and_every_other_owner(self):
        got = _secret_suffixes(self.deny)
        for want in (
            "${var.project}/${var.environment}/rds-??????",
            "${var.project}/${var.environment}/db-migrator-??????",
            "booking/*", "tripplanner/*", "crm/*", "aa-crm/*", "aa-ecosys/*", "aa-identity/*",
        ):
            with self.subTest(prefix=want):
                self.assertIn(want, got)

    def test_never_denies_what_cis_reads(self):
        # aa-llm/* is the LLM gateway's connection namespace; aa-cis/<env>/* and acp/* are CIS secrets.
        for suffix in _secret_suffixes(self.deny):
            with self.subTest(suffix=suffix):
                self.assertFalse(suffix.startswith(("aa-llm/", "acp/")), suffix)
                self.assertNotIn(suffix, {"${var.project}/*", "${var.project}/${var.environment}/*"})

    def test_master_pattern_stays_exact(self):
        # "rds-??????" (6 random characters) must not widen to "rds-*", which would also deny rds-app-user and
        # rds-cis-app, the DSNs the CIS runtime uses.
        self.assertNotRegex(self.deny, r"/rds-\*")


class ApplyBoundarySecretDenyTest(unittest.TestCase):
    def setUp(self):
        boundary_start = CICD_SPLIT.index('data "aws_iam_policy_document" "tf_apply_boundary"')
        self.boundary = _block_after(CICD_SPLIT, boundary_start)
        self.deny = _statement(self.boundary, "DenySecretValuesTerraformDoesNotRefresh")

    def test_deny_everything_but_the_plan_read_list(self):
        self.assertRegex(self.deny, r'effect\s*=\s*"Deny"')
        self.assertRegex(self.deny, r'actions\s*=\s*\["secretsmanager:GetSecretValue"\]')
        self.assertRegex(self.deny, r"not_resources\s*=\s*local\.tf_plan_secret_arns\b")
        self.assertNotRegex(self.deny, r"\bresources\s*=")

    def test_plan_role_reads_the_same_list(self):
        stmt = _statement(CICD_SPLIT, "ReadStackSecretValues")
        self.assertRegex(stmt, r"Resource\s*=\s*local\.tf_plan_secret_arns\b")

    def test_list_names_no_wildcard(self):
        self.assertNotIn("*\"", TF_PLAN_SECRET_ARNS)
        self.assertNotRegex(TF_PLAN_SECRET_ARNS, r":secret:")

    def test_every_secret_version_in_the_root_is_in_the_list(self):
        found = 0
        for f in sorted(AA365.glob("*.tf")):
            text = f.read_text(encoding="utf-8")
            for m in re.finditer(r'^(resource|data) "aws_secretsmanager_secret_version" "([a-z0-9_]+)"', text, re.M):
                found += 1
                block = _block_after(text, m.end())
                sid = re.search(r"secret_id\s*=\s*(\S+)", block).group(1)
                ref = re.match(r"aws_secretsmanager_secret\.([a-z0-9_]+)", sid)
                if ref:
                    want = f"aws_secretsmanager_secret.{ref.group(1)}"
                else:
                    self.assertTrue(sid.startswith("var."), f"{f.name}: {m.group(2)} secret_id {sid}")
                    want = sid
                with self.subTest(version=m.group(2), file=f.name):
                    self.assertIn(want, TF_PLAN_SECRET_ARNS)
        self.assertGreaterEqual(found, 6)

    def test_module_secret_versions_are_in_the_list(self):
        # modules/elasticache owns the Redis AUTH version (write-only value, refresh still reads it).
        mod = (ROOT / "modules" / "elasticache" / "main.tf").read_text(encoding="utf-8")
        self.assertIn('resource "aws_secretsmanager_secret_version" "redis_auth"', mod)
        self.assertIn("module.elasticache.auth_secret_arn", TF_PLAN_SECRET_ARNS)
        for d in sorted((ROOT / "modules").iterdir()):
            if d.name == "elasticache" or not d.is_dir():
                continue
            for f in d.glob("*.tf"):
                with self.subTest(file=str(f.relative_to(ROOT))):
                    self.assertNotRegex(f.read_text(encoding="utf-8"),
                                        r'^(resource|data) "aws_secretsmanager_secret_version"',
                                        "new secret version in a module: add its secret ARN to tf_plan_secret_arns")


class EcosystemGuardedSecretsTest(unittest.TestCase):
    """Review fix (S261): the apply role must not reach the ops / identity secrets through a role it writes and
    runs, nor by deleting or rewriting their resource policies."""

    def setUp(self):
        self.list = _bracket_after(CICD_SPLIT, CICD_SPLIT.index("ecosystem_guarded_secret_arns ="))
        self.workload = _block_after(
            CICD_SPLIT, CICD_SPLIT.index('data "aws_iam_policy_document" "workload_boundary"'))
        self.apply = _block_after(
            CICD_SPLIT, CICD_SPLIT.index('data "aws_iam_policy_document" "tf_apply_boundary"'))

    def test_list_is_both_prefixes_in_every_region(self):
        self.assertEqual(
            set(re.findall(r'"([^"]+)"', self.list)),
            {
                "arn:aws:secretsmanager:*:${var.account_id}:secret:aa-ecosys/*",
                "arn:aws:secretsmanager:*:${var.account_id}:secret:aa-identity/*",
            },
        )

    def test_workload_boundary_denies_reading_them(self):
        stmt = _statement(self.workload, "DenyEcosystemGuardedSecretValues")
        self.assertRegex(stmt, r'effect\s*=\s*"Deny"')
        self.assertRegex(stmt, r'actions\s*=\s*\["secretsmanager:GetSecretValue"\]')
        self.assertRegex(stmt, r"\bresources\s*=\s*local\.ecosystem_guarded_secret_arns\b")
        self.assertNotIn("condition", stmt)

    def test_apply_boundary_denies_policy_edits_and_replication(self):
        stmt = _statement(self.apply, "DenyEcosystemGuardedSecretPolicyEdits")
        self.assertRegex(stmt, r'effect\s*=\s*"Deny"')
        for action in ("PutResourcePolicy", "DeleteResourcePolicy", "ReplicateSecretToRegions"):
            with self.subTest(action=action):
                self.assertIn(f'"secretsmanager:{action}"', stmt)
        self.assertRegex(stmt, r"\bresources\s*=\s*local\.ecosystem_guarded_secret_arns\b")
        self.assertNotIn("condition", stmt)

    def test_the_guarded_secrets_are_in_the_list(self):
        # Every secret a guard covers (ops keys, break-glass) sits under one of the two prefixes.
        names = re.findall(r'=\s*"([^"]+)"', _block_after(OPS_GUARD, OPS_GUARD.index("ops_secret_names")))
        self.assertTrue(names)
        for name in names:
            with self.subTest(name=name):
                self.assertTrue(name.startswith("aa-ecosys/"), name)
        identity = (AA365 / "identity.tf").read_text(encoding="utf-8")
        self.assertIn('name                    = "aa-identity/${var.environment}/breakglass"', identity)

    def test_no_terraform_read_falls_under_the_prefixes(self):
        # The apply role keeps reading tf_plan_secret_arns; none may be an aa-ecosys/ or aa-identity/ secret, or the
        # workload Deny would not matter but the apply exception would undo the point of the guard.
        self.assertNotRegex(TF_PLAN_SECRET_ARNS, r"aa-ecosys|aa-identity|identity_breakglass")


class OpsSecretPolicyTest(unittest.TestCase):
    def test_both_ops_keys_are_covered(self):
        names = set(re.findall(r'=\s*"(aa-ecosys/[^"]+)"', OPS_GUARD))
        self.assertEqual(names, {"aa-ecosys/github/aa-agent-app-key", "aa-ecosys/ops/linear-api-key"})

    def test_referenced_not_managed(self):
        # The secrets were created with the CLI: a resource would recreate (or fail to create) them.
        self.assertNotIn('resource "aws_secretsmanager_secret" ', OPS_GUARD)
        self.assertNotIn("aws_secretsmanager_secret_version", OPS_GUARD.split("=====\n", 2)[-1])
        self.assertIn('data "aws_secretsmanager_secret" "ops"', OPS_GUARD)
        self.assertRegex(OPS_GUARD, r"secret_arn\s*=\s*data\.aws_secretsmanager_secret\.ops\[each\.key\]\.arn")
        self.assertRegex(OPS_GUARD, r"block_public_policy\s*=\s*true")

    def test_deny_value_calls_except_admin_role(self):
        stmt = _statement(OPS_GUARD, "DenyValueAccessExceptAdminRole")
        self.assertRegex(stmt, r'effect\s*=\s*"Deny"')
        for action in ("GetSecretValue", "PutSecretValue", "UpdateSecret", "RotateSecret", "ReplicateSecretToRegions"):
            with self.subTest(action=action):
                self.assertIn(f'"secretsmanager:{action}"', stmt)
        self.assertRegex(stmt, r'identifiers\s*=\s*\["\*"\]')
        self.assertRegex(stmt, r'test\s*=\s*"StringNotEquals"')
        self.assertRegex(stmt, r'variable\s*=\s*"aws:PrincipalArn"')
        self.assertRegex(stmt, r"values\s*=\s*local\.ops_secret_reader_role_arns")
        # Refresh and the CI apply need these; denying them would break plan or lock the policy.
        for action in ("DescribeSecret", "GetResourcePolicy", "PutResourcePolicy"):
            self.assertNotIn(f'"secretsmanager:{action}"', stmt)

    def test_reader_is_the_mfa_admin_role_only(self):
        m = re.search(r"ops_secret_reader_role_arns\s*=\s*(\[[^\]]*\])", OPS_GUARD)
        self.assertEqual(m.group(1), "[local.id_breakglass_admin_role_arn]")
        self.assertRegex(IDENTITY_ALERTS,
                         r'id_breakglass_admin_role_arn\s*=\s*"arn:aws:iam::\$\{var\.account_id\}:role/'
                         r'\$\{var\.identity_breakglass_admin_role_name\}"')


if __name__ == "__main__":
    unittest.main()
