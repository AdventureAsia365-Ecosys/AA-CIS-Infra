"""S263 (AA-939 follow-up, root ADR 0006b amendment A1): offline guards for AdminDeleteUser on the partner pool.

1. The CRM API task role's partner-pool allow-list (identity_partner.tf ``crm_ecs_task_partner_pool``) is exactly the
   five actions of the ADR, AdminDeleteUser included, on the partner pool only: no password, MFA or attribute write.
2. The partner admin-bypass alert (``identity_partner_admin_bypass``) still alerts on AdminDeleteUser by anyone but the
   CRM task role (the app audits its own deletes), and on every takeover action by anyone at all.
3. The staff pools never get a delete: the CIS directory role keeps AdminDeleteUser in its explicit Deny on WORKFORCE
   and EXTERNAL (identity_iam.tf), and no allow statement there names it.

Run: python3 -m pytest -q tools/terraform/tests/test_partner_pool_delete_user.py
"""
import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
AA365 = ROOT / "accounts" / "aa365"
PARTNER = (AA365 / "identity_partner.tf").read_text(encoding="utf-8")
IAM = (AA365 / "identity_iam.tf").read_text(encoding="utf-8")
WORKFLOW = (ROOT / ".github" / "workflows" / "tf-plan-guard-test.yml").read_text(encoding="utf-8")


def _resource(text: str, kind: str, name: str) -> str:
    m = re.search(rf'^resource "{kind}" "{name}" \{{', text, re.M)
    assert m, f"{kind}.{name} not found"
    body = text[m.end():]
    end = re.search(r"^\}", body, re.M)
    return body[: end.start()]


def _list(text: str, key: str) -> list[str]:
    m = re.search(rf"{key}\s*=\s*(\[[^\]]*\])", text)
    assert m, f"{key} not found"
    return json.loads(m.group(1))


class PartnerPoolDeleteUser(unittest.TestCase):
    def test_the_crm_allow_list_is_exactly_the_adr_five_on_the_partner_pool(self) -> None:
        body = _resource(PARTNER, "aws_iam_role_policy", "crm_ecs_task_partner_pool")
        actions = _list(body, "Action")
        self.assertEqual(
            sorted(actions),
            sorted(
                [
                    "cognito-idp:AdminCreateUser",
                    "cognito-idp:ListUsers",
                    "cognito-idp:AdminDisableUser",
                    "cognito-idp:AdminUserGlobalSignOut",
                    "cognito-idp:AdminDeleteUser",
                ]
            ),
        )
        self.assertIn("role = aws_iam_role.crm_ecs_task.id", body)
        self.assertIn("Resource = aws_cognito_user_pool.partner.arn", body)
        self.assertNotIn("*", "".join(actions))

    def test_the_bypass_alert_excludes_only_the_crm_role_for_create_and_delete(self) -> None:
        body = _resource(PARTNER, "aws_cloudwatch_event_rule", "identity_partner_admin_bypass")
        always = _list(body, r'\{ eventName')
        for action in ("AdminSetUserPassword", "AdminResetUserPassword", "AdminSetUserMFAPreference",
                       "AdminUpdateUserAttributes", "AdminDeleteUserAttributes", "AdminEnableUser",
                       "AdminLinkProviderForUser"):  # fmt: skip
            self.assertIn(action, always)
        self.assertNotIn("AdminDeleteUser", always)
        m = re.search(r'eventName = (\[[^\]]*\])\s*\n\s*userIdentity = \{(.*?)\n        \}', body, re.S)
        assert m, "the CRM-role exception block not found"
        self.assertEqual(sorted(json.loads(m.group(1))), ["AdminCreateUser", "AdminDeleteUser"])
        self.assertRegex(
            m.group(2),
            r'arn = \[\{ "anything-but" = \[aws_iam_role\.crm_ecs_task\.arn\] \}, \{ exists = false \}\]',
        )

    def test_the_staff_pools_never_get_a_delete(self) -> None:
        deny = re.search(r'sid\s*=\s*"DenyStaffTakeoverActions"(.*?)\n  \}', IAM, re.S)
        assert deny, "DenyStaffTakeoverActions not found"
        self.assertIn('"cognito-idp:AdminDeleteUser"', deny.group(1))
        self.assertIn("aws_cognito_user_pool.workforce.arn", deny.group(1))
        self.assertIn("aws_cognito_user_pool.external.arn", deny.group(1))
        allow = re.search(r'sid\s*=\s*"WorkforceDirectoryWrite"(.*?)\n  \}', IAM, re.S)
        assert allow, "WorkforceDirectoryWrite not found"
        self.assertNotIn("AdminDeleteUser", allow.group(1))

    def test_this_workflow_runs_when_the_files_change(self) -> None:
        for path in ("accounts/aa365/identity_partner.tf", "accounts/aa365/identity_iam.tf"):
            self.assertGreaterEqual(WORKFLOW.count(f'"{path}"'), 2, path)


if __name__ == "__main__":
    unittest.main()
