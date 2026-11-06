"""Tests of tools/terraform/iam_trust_inventory.py (S271 lessons guard G13).

The S271 lesson: an audit that reads only Principal.AWS misses a Federated (SAML) trust such as the Identity Center
role AWSReservedSSO_AdministratorAccess_*, which no Terraform file creates and whose Access Analyzer finding is
ARCHIVED. These tests hold the tool to every principal kind (AWS, Federated SAML / OIDC, Service, `*`, NotPrincipal),
to its live mode (unmanaged external trust reported), and run its static mode over this repo: a new flagged trust in
the Terraform roots fails here until it is reviewed and acknowledged in tools/terraform/iam_trust_allowlist.json.

Fixtures use invented account ids (111111111111 = this account, 222222222222 = an ecosystem account,
999999999999 = an outside account) and invented role names. Offline: no AWS, no Terraform.
Run: python3 -m pytest -p no:cacheprovider -q tools/terraform/tests/test_iam_trust_inventory.py
"""
from __future__ import annotations

import json
import os
import sys
import textwrap

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.abspath(os.path.join(HERE, "..")))
import iam_trust_inventory as inv  # noqa: E402

FIX = os.path.join(HERE, "fixtures")
SELF, ECO, EXT = "111111111111", "222222222222", "999999999999"
ALLOW = {"services": ["ecs-tasks.amazonaws.com", "lambda.amazonaws.com"],
         "oidc_providers": ["token.actions.githubusercontent.com"], "acknowledged": []}


def _ctx(**kw) -> inv.Context:
    allow = dict(ALLOW, **{k: v for k, v in kw.items() if k in ALLOW})
    return inv.make_context(allow, kw.get("self_accounts", [SELF]), static=kw.get("static", False),
                            accounts_env=kw.get("accounts_env", f"eco={ECO}"))


def _fake_runner(calls: list | None = None):
    with open(os.path.join(FIX, "iam_trust_live.json"), encoding="utf-8") as fh:
        data = json.load(fh)

    def run(args: list) -> dict:
        if calls is not None:
            calls.append(args)
        if args[:2] == ["iam", "get-role"]:
            return data["get-role"][args[args.index("--role-name") + 1]]
        return data[" ".join(args[:2])]
    return run


def _by(trusts, role_part: str, kind: str | None = None):
    found = [t for t in trusts if role_part in t.role and (kind is None or t.kind == kind)]
    assert found, (role_part, [t.role for t in trusts])
    return found


# --- classification of each principal kind ---------------------------------------------------------------------------

@pytest.mark.parametrize("kind,principal,verdict,needle", [
    ("AWS", f"arn:aws:iam::{SELF}:role/demo-task", inv.OK, "this account"),
    ("AWS", SELF, inv.OK, "this account"),
    ("AWS", f"arn:aws:iam::{ECO}:role/demo-worker", inv.LISTED, "ecosystem account eco"),
    ("AWS", f"arn:aws:iam::{EXT}:root", inv.FLAG, "external account"),
    ("AWS", "*", inv.FLAG, "public"),
    ("*", "*", inv.FLAG, "public"),
    ("Federated", f"arn:aws:iam::{SELF}:saml-provider/AWSSSO_0000000000000000_DO_NOT_DELETE", inv.FLAG,
     "IAM Identity Center"),
    ("Federated", f"arn:aws:iam::{SELF}:saml-provider/DemoCorpIdP", inv.FLAG, "external identity provider"),
    ("Federated", "accounts.google.com", inv.FLAG, "not in the allowlist"),
    ("Federated", "cognito-identity.amazonaws.com", inv.FLAG, "not in the allowlist"),
    ("Federated", f"arn:aws:iam::{EXT}:oidc-provider/token.actions.githubusercontent.com", inv.FLAG,
     "another account"),
    ("Service", "ecs-tasks.amazonaws.com", inv.OK, "allowlisted"),
    ("Service", "glue.amazonaws.com", inv.FLAG, "not in the allowlist"),
    ("CanonicalUser", "79a59df900b949e55d96a1e698fbaced", inv.FLAG, "CanonicalUser"),
    ("NotPrincipal", '{"AWS": "x"}', inv.FLAG, "NotPrincipal"),
])
def test_classify_each_principal_kind(kind, principal, verdict, needle):
    cond = '{"StringEquals": {"token.actions.githubusercontent.com:sub": "repo:o/r:ref:refs/heads/main"}}'
    got, note = inv.classify(kind, principal, _ctx(), cond)
    assert got == verdict and needle in note, (got, note)


def test_github_oidc_needs_a_sub_condition():
    p = f"arn:aws:iam::{SELF}:oidc-provider/token.actions.githubusercontent.com"
    assert inv.classify("Federated", p, _ctx(), '{"StringEquals": {"token.actions.githubusercontent.com:sub": "x"}}')[0] == inv.LISTED
    verdict, note = inv.classify("Federated", p, _ctx(), '{"StringEquals": {"token.actions.githubusercontent.com:aud": "sts"}}')
    assert verdict == inv.FLAG and ":sub" in note


def test_without_known_accounts_every_literal_account_is_flagged():
    ctx = inv.make_context(ALLOW, [], accounts_env="")
    assert inv.classify("AWS", f"arn:aws:iam::{SELF}:root", ctx)[0] == inv.FLAG


def test_static_expressions_same_root_and_unknown():
    ctx = _ctx(static=True, self_accounts=[])
    assert inv.classify("AWS", "arn:aws:iam::${var.account_id}:root", ctx)[0] == inv.OK
    assert inv.classify("AWS", "aws_iam_role.demo.arn", ctx)[0] == inv.OK
    assert inv.classify("AWS", "var.partner_role_arn", ctx)[0] == inv.FLAG
    assert inv.classify("Service", "var.service_principal", ctx)[0] == inv.FLAG
    assert inv.classify("Federated", "aws_iam_saml_provider.corp.arn", ctx)[0] == inv.FLAG
    sub = 'variable = "token.actions.githubusercontent.com:sub"'
    assert inv.classify("Federated", "var.github_oidc_provider_arn", ctx, sub)[0] == inv.LISTED
    assert inv.classify("Federated", "var.github_oidc_provider_arn", ctx, "")[0] == inv.FLAG


def test_deny_statements_are_skipped_and_url_encoded_policies_read():
    doc = {"Statement": [{"Effect": "Deny", "Principal": "*", "Action": "sts:AssumeRole"},
                         {"Effect": "Allow", "Principal": {"Service": "lambda.amazonaws.com"}, "Action": "sts:AssumeRole"}]}
    import urllib.parse
    for form in (doc, json.dumps(doc), urllib.parse.quote(json.dumps(doc))):
        trusts = inv.trusts_from_policy("live", "live:r", "r", form, _ctx())
        assert [(t.kind, t.verdict) for t in trusts] == [("Service", inv.OK)]


def test_acknowledgement_keeps_the_row_visible():
    ctx = _ctx(acknowledged=[{"match": "live:demo-vendor-*", "kind": "AWS", "reason": "reviewed vendor audit"}])
    doc = {"Statement": [{"Effect": "Allow", "Principal": {"AWS": f"arn:aws:iam::{EXT}:root"}, "Action": "sts:AssumeRole"}]}
    (t,) = inv.trusts_from_policy("live", "live:demo-vendor-audit", "demo-vendor-audit", doc, ctx)
    assert t.verdict == inv.ACK and "reviewed vendor audit" in t.note
    (u,) = inv.trusts_from_policy("live", "live:demo-other", "demo-other", doc, ctx)
    assert u.verdict == inv.FLAG


# --- live mode -------------------------------------------------------------------------------------------------------

def test_live_reports_the_identity_center_role_as_unmanaged_external_trust():
    calls = []
    trusts = inv.live_trusts(_fake_runner(calls), _ctx(self_accounts=[]), access_analyzer=True)
    (sso,) = _by(trusts, "AWSReservedSSO_AdministratorAccess_")
    assert sso.kind == "Federated" and sso.verdict == inv.FLAG
    assert sso.managed == "identity-center (not Terraform)"
    assert sso.note.startswith("UNMANAGED external trust: SAML federation: IAM Identity Center")
    assert sso.analyzer == "ARCHIVED" and "absent from ACTIVE findings" in sso.note
    # Read-only calls only, never a get-role on the aws-reserved / service-linked paths.
    verbs = {(c[0], c[1]) for c in calls}
    assert verbs <= {("sts", "get-caller-identity"), ("iam", "list-roles"), ("iam", "get-role"),
                     ("accessanalyzer", "list-analyzers"), ("accessanalyzer", "list-findings-v2")}
    assert not any("AWSReservedSSO" in " ".join(c) or "AWSServiceRole" in " ".join(c) for c in calls)


def test_live_classifies_aws_federated_and_service_principals():
    trusts = inv.live_trusts(_fake_runner(), _ctx(self_accounts=[]))
    vendor = _by(trusts, "demo-vendor-audit")[0]
    assert vendor.verdict == inv.FLAG and vendor.managed == "unmanaged" and "external account" in vendor.note
    assert vendor.note.startswith("UNMANAGED external trust")
    satellite = {t.principal: t for t in _by(trusts, "demo-satellite-caller")}
    assert satellite[f"arn:aws:iam::{ECO}:role/demo-worker"].verdict == inv.LISTED
    assert satellite[SELF].verdict == inv.OK
    assert _by(trusts, "demo-api-task")[0].verdict == inv.OK
    assert _by(trusts, "demo-api-task")[0].managed == "terraform (tag)"
    glue = _by(trusts, "demo-glue-job")[0]
    assert glue.verdict == inv.FLAG and glue.managed == "unmanaged"  # ManagedBy=manual is not Terraform
    assert _by(trusts, "demo-ci-deploy")[0].verdict == inv.LISTED
    loose = _by(trusts, "demo-ci-loose")[0]
    assert loose.verdict == inv.FLAG and ":sub" in loose.note and not loose.note.startswith("UNMANAGED")
    support = _by(trusts, "AWSServiceRoleForSupport")[0]
    assert support.verdict == inv.OK and support.managed == "service-linked (AWS)"
    assert [t.kind for t in _by(trusts, "demo-denied")] == ["Service"]


def test_live_managed_from_skips_the_tag_lookup():
    calls = []
    with open(os.path.join(FIX, "iam_trust_plan.json"), encoding="utf-8") as fh:
        names = inv.managed_role_names(json.load(fh))
    assert names == {"demo-api-task", "demo-new-role", "demo-satellite-caller", "demo-vendor-audit"}
    trusts = inv.live_trusts(_fake_runner(calls), _ctx(self_accounts=[]), names)
    assert _by(trusts, "demo-vendor-audit")[0].managed == "terraform"
    asked = {c[c.index("--role-name") + 1] for c in calls if c[:2] == ["iam", "get-role"]}
    assert asked == {"demo-glue-job", "demo-ci-deploy", "demo-ci-loose", "demo-denied"}


def test_live_cli_exit_code_and_masked_report(capsys, monkeypatch):
    monkeypatch.setenv(inv.ACCOUNTS_ENV, f"eco={ECO}")
    monkeypatch.delenv("AWS_ACCOUNT_ALIASES", raising=False)
    rc = inv.main(["live", "--access-analyzer"], runner=_fake_runner())
    out = capsys.readouterr().out
    assert rc == 1
    assert "AWSReservedSSO_AdministratorAccess_" in out and "UNMANAGED external trust" in out
    assert "| Managed by | Access Analyzer |" in out
    for acct in (SELF, ECO, EXT):
        assert acct not in out  # masked: public run logs


# --- plan mode -------------------------------------------------------------------------------------------------------

def test_plan_reads_child_modules_and_unknown_policies(capsys):
    rc = inv.main(["plan", "--json-file", os.path.join(FIX, "iam_trust_plan.json"), "--self-account", SELF])
    out = capsys.readouterr().out
    assert rc == 1  # the vendor role trusts an outside account
    assert "module.env.aws_iam_role.vendor" in out and "external account" in out
    assert "aws_iam_role.new_role" in out and "known only after apply" in out
    assert "aws_s3_bucket" not in out and SELF not in out


def test_json_output(capsys):
    inv.main(["plan", "--json", "--json-file", os.path.join(FIX, "iam_trust_plan.json"), "--self-account", SELF])
    rows = json.loads(capsys.readouterr().out)
    assert {r["mode"] for r in rows} == {"plan"} and {"key", "kind", "verdict", "note"} <= set(rows[0])


def test_bad_inputs_exit_2(tmp_path, capsys):
    bad = tmp_path / "allow.json"
    bad.write_text(json.dumps({"services": [], "acknowledged": [{"match": "x", "kind": "AWS"}]}))
    assert inv.main(["static", "--allowlist", str(bad)]) == 2
    bad.write_text(json.dumps({"services": [], "acknowledged": [], "note": f"see {EXT}"}))
    assert inv.main(["static", "--allowlist", str(bad)]) == 2
    with pytest.raises(ValueError):
        inv.parse_accounts("eco=12345")


# --- static mode -----------------------------------------------------------------------------------------------------

STATIC_TF = textwrap.dedent('''
    # resource "aws_iam_role" "commented" { assume_role_policy = "x" }
    resource "aws_iam_role" "task" {
      name = "demo-task"
      assume_role_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Effect    = "Allow"
          Principal = { Service = "ecs-tasks.amazonaws.com" }
          Action    = "sts:AssumeRole"
        }]
      })
      tags = { Note = "braces in a string: { }" }
    }

    resource "aws_iam_role" "deploy" {
      name = "demo-deploy"
      assume_role_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Effect    = "Allow"
          Principal = { Federated = aws_iam_openid_connect_provider.github_actions.arn }
          Action    = "sts:AssumeRoleWithWebIdentity"
          Condition = {
            StringEquals = {
              "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
              "token.actions.githubusercontent.com:sub" = "repo:example-org/example-repo:ref:refs/heads/main"
            }
          }
        }]
      })
    }

    resource "aws_iam_role" "partner" {
      name               = "demo-partner"
      assume_role_policy = data.aws_iam_policy_document.partner_trust.json
    }

    data "aws_iam_policy_document" "partner_trust" {
      statement {
        effect  = "Deny"
        actions = ["sts:AssumeRole"]
        principals {
          type        = "AWS"
          identifiers = ["*"]
        }
      }
      statement {
        actions = ["sts:AssumeRole", "sts:TagSession"]
        principals {
          type        = "AWS"
          identifiers = ["arn:aws:iam::999999999999:root", "arn:aws:iam::${var.account_id}:root"]
        }
        principals {
          type        = "Service"
          identifiers = ["lambda.amazonaws.com"]
        }
      }
    }

    resource "aws_iam_role" "sso" {
      name               = "demo-sso"
      assume_role_policy = data.aws_iam_policy_document.sso_trust.json
    }

    data "aws_iam_policy_document" "sso_trust" {
      statement {
        actions = ["sts:AssumeRoleWithSAML"]
        principals {
          type        = "Federated"
          identifiers = [aws_iam_saml_provider.corp.arn]
        }
      }
    }

    resource "aws_iam_role" "opaque" {
      name               = "demo-opaque"
      assume_role_policy = file("${path.module}/trust.json")
    }
''')


@pytest.fixture()
def tf_repo(tmp_path):
    root = tmp_path / "accounts" / "demo"
    root.mkdir(parents=True)
    (root / "iam.tf").write_text(STATIC_TF, encoding="utf-8")
    (tmp_path / "modules" / "empty").mkdir(parents=True)
    return tmp_path


def test_static_reads_jsonencode_and_policy_documents(tf_repo):
    trusts = inv.static_trusts(_ctx(static=True, self_accounts=[], accounts_env=""), str(tf_repo))
    got = {(t.key, t.kind, t.principal): t.verdict for t in trusts}
    assert got == {
        ("accounts/demo:aws_iam_role.task", "Service", "ecs-tasks.amazonaws.com"): inv.OK,
        ("accounts/demo:aws_iam_role.deploy", "Federated", "aws_iam_openid_connect_provider.github_actions.arn"): inv.LISTED,
        ("accounts/demo:aws_iam_role.partner", "AWS", "arn:aws:iam::999999999999:root"): inv.FLAG,
        ("accounts/demo:aws_iam_role.partner", "AWS", "arn:aws:iam::${var.account_id}:root"): inv.OK,
        ("accounts/demo:aws_iam_role.partner", "Service", "lambda.amazonaws.com"): inv.OK,
        ("accounts/demo:aws_iam_role.sso", "Federated", "aws_iam_saml_provider.corp.arn"): inv.FLAG,
        ("accounts/demo:aws_iam_role.opaque", "unresolved", 'file("${path.module}/trust.json")'): inv.FLAG,
    }
    partner = _by(trusts, "partner", "Service")[0]
    assert partner.actions == "sts:AssumeRole,sts:TagSession"
    assert _by(trusts, "deploy")[0].actions == "sts:AssumeRoleWithWebIdentity"


def test_static_acknowledgement_by_dir_and_address(tf_repo):
    ctx = _ctx(static=True, self_accounts=[], accounts_env="",
               acknowledged=[{"match": "accounts/demo:aws_iam_role.partner", "kind": "AWS", "reason": "demo partner"}])
    trusts = inv.static_trusts(ctx, str(tf_repo))
    partner_aws = [t for t in _by(trusts, "partner", "AWS") if "999999999999" in t.principal][0]
    assert partner_aws.verdict == inv.ACK
    assert _by(trusts, "sso")[0].verdict == inv.FLAG  # another kind / role is not covered


def test_this_repo_has_no_unreviewed_trust(capsys):
    """The guard: every aws_iam_role trust in accounts/ and modules/ is ok, listed or acknowledged."""
    rc = inv.main(["static"])
    out = capsys.readouterr().out
    flagged = [line for line in out.splitlines() if line.startswith("| FLAG |")]
    assert rc == 0, "review these trusts, then acknowledge them in tools/terraform/iam_trust_allowlist.json:\n" + \
        "\n".join(flagged)


def test_this_repo_scan_is_not_vacuous():
    trusts = inv.static_trusts(inv.make_context(inv.load_allowlist(inv.DEFAULT_ALLOWLIST), static=True, accounts_env=""))
    roles = {t.key for t in trusts}
    assert len(roles) >= 40
    kinds = {t.kind for t in trusts}
    assert {"AWS", "Federated", "Service"} <= kinds and "unresolved" not in kinds
    # Every GitHub OIDC role of the roots pins the sub claim.
    oidc = [t for t in trusts if t.kind == "Federated"]
    assert len(oidc) >= 10 and all(t.verdict == inv.LISTED for t in oidc)


def test_allowlist_holds_no_account_id_and_every_ack_has_a_reason():
    with open(inv.DEFAULT_ALLOWLIST, encoding="utf-8") as fh:
        text = fh.read()
    assert not inv.ACCOUNT_IN.search(text)
    data = json.loads(text)
    assert all(e["reason"].strip() for e in data["acknowledged"])
    assert not any("AWSReservedSSO" in e["match"] for e in data["acknowledged"])  # must stay visible


def test_the_required_plan_check_runs_the_static_inventory_before_any_credential():
    import yaml

    with open(os.path.join(inv.REPO_ROOT, ".github", "workflows", "terraform-plan.yml"), encoding="utf-8") as fh:
        job = yaml.safe_load(fh)["jobs"]["terraform-plan"]
    assert job["name"] == "Terraform Plan (dev)"
    names = [s.get("name", "") for s in job["steps"]]
    step = job["steps"][names.index("IAM trust inventory (static)")]
    assert names.index("IAM trust inventory (static)") < names.index("Configure AWS credentials (OIDC)")
    assert "tools/terraform/iam_trust_inventory.py static" in step["run"]
    assert "continue-on-error" not in step and "if" not in step and "env" not in step
