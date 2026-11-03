"""AA-1039 R6 slice 2 (root ADR 0019 d20): offline guards for the CIS task role's read of the partner pool.

1. The allow statement is exactly cognito-idp:ListUsers on the partner pool ARN (the tour notice e-mail looks up a
   member's verified address by sub; nothing that writes, creates or signs in).
2. An explicit Deny keeps every other action off the partner pool for the CIS role (NotAction ListUsers): the
   takeover and create calls and the pool, app-client and identity-provider configuration writes.
3. The policy is attached to the CIS ECS task role (api and worker), and tf-plan-guard-test runs when the file changes.

Run: python3 -m pytest -q tools/terraform/tests/test_aa1039_cis_partner_pool_read.py
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
TF = (ROOT / "accounts" / "aa365" / "identity_partner_read.tf").read_text(encoding="utf-8")
WORKFLOW = (ROOT / ".github" / "workflows" / "tf-plan-guard-test.yml").read_text(encoding="utf-8")


def _statement(sid: str) -> str:
    m = re.search(rf'sid\s*=\s*"{sid}"(.*?)\n  \}}', TF, re.S)
    assert m, f"statement {sid} not found"
    return m.group(1)


def _actions(body: str) -> list[str]:
    m = re.search(r"actions\s*=\s*\[(.*?)\]", body, re.S)
    assert m, "actions not found"
    return re.findall(r'"([^"]+)"', m.group(1))


class CisPartnerPoolRead(unittest.TestCase):
    def test_the_allow_is_list_users_on_the_partner_pool_only(self) -> None:
        body = _statement("PartnerPoolMemberAddressRead")
        self.assertIn('effect    = "Allow"', body)
        self.assertEqual(_actions(body), ["cognito-idp:ListUsers"])
        self.assertIn("resources = [aws_cognito_user_pool.partner.arn]", body)

    def test_every_other_partner_pool_action_is_denied(self) -> None:
        """NotAction ListUsers: the per-user takeover calls and the pool, app-client and IdP configuration writes
        (a callback URL added to the hosted-UI client, a new IdP, triggers, MFA off) are all denied."""
        body = _statement("DenyPartnerTakeoverActions")
        self.assertIn('effect      = "Deny"', body)
        m = re.search(r"not_actions\s*=\s*\[(.*?)\]", body, re.S)
        assert m, "not_actions not found"
        excepted = re.findall(r'"([^"]+)"', m.group(1))
        self.assertEqual(excepted, ["cognito-idp:ListUsers"])
        self.assertNotRegex(body, r"(?m)^\s*actions\s*=")
        self.assertIn("resources   = [aws_cognito_user_pool.partner.arn]", body)
        for action in ("AdminSetUserPassword", "AdminUpdateUserAttributes", "AdminLinkProviderForUser",
                       "AdminInitiateAuth", "AdminRespondToAuthChallenge", "AdminDeleteUser", "AdminCreateUser",
                       "AdminSetUserMFAPreference", "AdminResetUserPassword", "AdminConfirmSignUp",
                       "AdminAddUserToGroup", "UpdateUserPoolClient", "CreateUserPoolClient",
                       "CreateIdentityProvider", "UpdateIdentityProvider", "UpdateUserPool", "SetUserPoolMfaConfig"):
            self.assertNotIn(f"cognito-idp:{action}", excepted)

    def test_attached_to_the_cis_task_role(self) -> None:
        m = re.search(r'^resource "aws_iam_role_policy" "cis_ecs_task_partner_pool_read" \{(.*?)^\}', TF, re.S | re.M)
        assert m, "role policy not found"
        self.assertIn("role   = module.ecs.task_role_name", m.group(1))
        self.assertIn("data.aws_iam_policy_document.cis_partner_pool_read.json", m.group(1))

    def test_this_workflow_runs_when_the_file_changes(self) -> None:
        self.assertGreaterEqual(WORKFLOW.count('"accounts/aa365/identity_partner_read.tf"'), 2)


if __name__ == "__main__":
    unittest.main()
