"""AA-873 (S256): offline guards for the Access Analyzer archive rules and the IAM change alert.

1. Every IAM role trusted by the GitHub Actions OIDC provider is reviewed and listed in the archive rule
   (security_access_analyzer_archive.tf); a role missing there means its finding was never triaged.
2. Every such trust pins the audience and a subject without a wildcard (the analyzer cannot see the subject claim,
   so this test is what stands behind the archive rule).
3. The iam-change rule (security_baseline.tf) matches every IAM write verb the live check expects, tag changes
   included (tags drive access: the CRM break-glass key policy reads aws:PrincipalTag/tenant_id).

Run: python3 -m pytest -q tools/terraform/tests/test_sec_access_analyzer.py
"""
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
AA365 = ROOT / "accounts" / "aa365"
sys.path.insert(0, str(ROOT / "tools" / "terraform"))

import sec_alert_check as chk  # noqa: E402

ARCHIVE = (AA365 / "security_access_analyzer_archive.tf").read_text(encoding="utf-8")
BASELINE = (AA365 / "security_baseline.tf").read_text(encoding="utf-8")
TFVARS = (AA365 / "terraform.tfvars").read_text(encoding="utf-8")
OIDC_REF = "aws_iam_openid_connect_provider.github_actions.arn"


def _blocks(kind: str):
    """(name, block text) for every `resource "<kind>" "<name>"` in accounts/aa365."""
    for f in sorted(AA365.glob("*.tf")):
        text = f.read_text(encoding="utf-8")
        for m in re.finditer(rf'^resource "{kind}" "([a-z0-9_]+)" \{{', text, re.M):
            body = text[m.end():]
            end = re.search(r"^\}", body, re.M)
            yield m.group(1), f.name, body[: end.start() if end else len(body)]


def _local(name: str) -> str:
    for f in sorted(AA365.glob("*.tf")):
        m = re.search(rf"^\s*{name}\s*=\s*(.+?)(?=^\s*[a-z_0-9]+\s*=|\Z)", f.read_text(encoding="utf-8"), re.M | re.S)
        if m:
            return m.group(1)
    raise AssertionError(f"local {name} not found")


def oidc_roles():
    return [(n, f, b) for n, f, b in _blocks("aws_iam_role") if OIDC_REF in b]


class ArchiveRuleTest(unittest.TestCase):
    def test_there_are_oidc_roles(self):
        self.assertGreaterEqual(len(oidc_roles()), 9)

    def test_every_oidc_role_is_in_the_archive_rule(self):
        listed = set(re.findall(r"aws_iam_role\.([a-z0-9_]+)(?:\[\*\])?\.arn", ARCHIVE))
        for name, f, _ in oidc_roles():
            with self.subTest(role=name, file=f):
                self.assertIn(name, listed, "new GitHub OIDC role: review its trust, then add it to "
                                            "local.sec_aa_github_oidc_roles (security_access_analyzer_archive.tf)")

    def test_archive_rule_lists_only_oidc_roles(self):
        names = {n for n, _, _ in oidc_roles()}
        block = ARCHIVE.split("sec_aa_github_oidc_roles = concat(", 1)[1].split("\n  )", 1)[0]
        for ref in re.findall(r"aws_iam_role\.([a-z0-9_]+)", block):
            with self.subTest(role=ref):
                self.assertIn(ref, names)

    def test_every_oidc_trust_pins_audience_and_subject(self):
        for name, f, block in oidc_roles():
            with self.subTest(role=name, file=f):
                self.assertIn('"token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"', block)
                m = re.search(r'"token\.actions\.githubusercontent\.com:sub"\s*=\s*(\[.*?\]|.+)', block, re.S)
                sub = m.group(1)
                seen, todo = set(), set(re.findall(r"local\.([a-z0-9_]+)", sub))
                while todo:   # follow the locals the subject is built from (two levels today)
                    loc = todo.pop()
                    seen.add(loc)
                    text = _local(loc)
                    sub += "\n" + text
                    todo |= set(re.findall(r"local\.([a-z0-9_]+)", text)) - seen
                self.assertIn("repo:AdventureAsia365-Ecosys", sub)
                # A "*" repo id fallback (booking/crm) is covered by test_repo_id_variables_are_set.
                self.assertNotRegex(sub, r'repo:[^"]*\*|:\*"|/\*', "wildcard in the OIDC subject")

    def test_repo_id_variables_are_set(self):
        # booking.tf / crm_app.tf fall back to a "*" repo id (and the mutable owner/repo form) when these are empty.
        for var in ("booking_github_repo_id", "crm_github_repo_id"):
            with self.subTest(var=var):
                self.assertRegex(TFVARS, rf'(?m)^{var}\s*=\s*"\d+"')

    def test_other_rules_are_narrow(self):
        sso = ARCHIVE.split('resource "aws_accessanalyzer_archive_rule" "identity_center_admin"', 1)[1]
        sso = sso.split("\nresource ", 1)[0]
        self.assertIn("AWSReservedSSO_AdministratorAccess_", sso)
        bronze = ARCHIVE.split('resource "aws_accessanalyzer_archive_rule" "bronze_bedrock_batch"', 1)[1]
        for needle in ('"principal.AWS"', "module.s3.bronze_bucket_arn", '"isPublic"', 'eq       = ["false"]'):
            self.assertIn(needle, bronze)


class IamChangeRuleTest(unittest.TestCase):
    def _items(self):
        block = BASELINE.split('resource "aws_cloudwatch_event_rule" "sec_iam_change"', 1)[1].split("\nresource ", 1)[0]
        names = block.split("eventName = [", 1)[1].split("\n      ]", 1)[0]
        return re.findall(r'prefix = "([A-Za-z]+)"', names), re.findall(r'^\s*"([A-Za-z]+)"', names, re.M)

    def test_live_check_iam_verbs_are_matched(self):
        prefixes, exact = self._items()
        verbs = {c[0].split(".")[-1] for c in chk.cases("000000000000", "us-west-1", "dev")
                 if c[1].endswith("iam-change") and c[4]}
        self.assertTrue(set(chk.AFTER_S256) <= verbs)
        for v in verbs:
            with self.subTest(verb=v):
                self.assertTrue(v in exact or any(v.startswith(p) for p in prefixes))

    def test_no_read_verb_is_matched(self):
        prefixes, _ = self._items()
        for read in ("Get", "List", "Simulate", "Generate"):
            self.assertNotIn(read, prefixes)

    def test_live_check_rule_names_exist(self):
        for rule in {c[1] for c in chk.cases("000000000000", "us-west-1", "dev")}:
            suffix = rule.split("aa-sec-dev-", 1)[1]
            with self.subTest(rule=rule):
                self.assertIn(f'name        = "${{local.sec_prefix}}-{suffix}"', BASELINE)


if __name__ == "__main__":
    unittest.main()
