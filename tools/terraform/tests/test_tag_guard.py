"""Tests for tools/terraform/tag_guard.py and the tagging standard in the Terraform roots (S271, FIN-03).

Run from the repo root:

    python3 -m pytest -p no:cacheprovider -q tools/terraform/tests

Offline: synthetic plan JSON built here plus the fixtures plan_tags_ok.json / plan_tags_bad.json, no Terraform, no AWS.
The last tests read the Terraform roots and .github/workflows/terraform-plan.yml: every root's provider default_tags
carry the mandatory keys with allowed values, no tag map overrides them with an old spelling, and the guard stays
wired into the required "Terraform Plan (dev)" check.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys

import pytest
import yaml

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))

import tag_guard as tg  # noqa: E402

FIXTURES = os.path.join(HERE, "fixtures")
SCRIPT = os.path.join(HERE, "..", "tag_guard.py")
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
POLICY_PATH = os.path.join(REPO_ROOT, "tools", "terraform", "tag_policy.json")
PLAN_WF = os.path.join(REPO_ROOT, ".github", "workflows", "terraform-plan.yml")
AWS = "registry.terraform.io/hashicorp/aws"

GOOD = {
    "Environment": "dev",
    "Project": "aa-ecosys",
    "App": "cis",
    "Component": "api",
    "Owner": "tech-lead",
    "ManagedBy": "terraform",
    "CostCenter": "technology",
    "DataClassification": "internal",
}


@pytest.fixture(scope="module")
def policy() -> tg.Policy:
    return tg.load_policy(POLICY_PATH)


def _rc(address: str, tags, actions=("update",), rtype: str = "aws_lambda_function", unknown=None,
        provider: str = AWS, attr: str = "tags_all") -> dict:
    after = {} if tags is None else {attr: tags}
    change = {"actions": list(actions), "before": {}, "after": after, "after_unknown": unknown or {}}
    return {"address": address, "mode": "managed", "type": rtype, "provider_name": provider, "change": change}


def _plan(*rcs: dict) -> dict:
    return {"format_version": "1.2", "planned_values": {}, "resource_changes": list(rcs)}


def _kinds(violations) -> list[tuple[str, str]]:
    return [(v.kind, v.detail.split("=")[0].split(" ")[0]) for v in violations]


def _run(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, "-B", SCRIPT, *args], capture_output=True, text=True, check=False)


# --- the policy file -----------------------------------------------------------------------------------------------


def test_policy_lists_the_eight_mandatory_keys_and_today_app_values(policy):
    assert set(policy.mandatory) == set(GOOD)
    # The seven App values Cost Explorer already shows (S271); a new one needs a root doc change first.
    assert policy.mandatory["App"] == {"cis", "booking", "tripplanner", "crm", "identity", "shared", "ecosystem"}
    assert policy.mandatory["Environment"] >= {"dev", "staging", "prod"}  # root ADR 0018 decision 2
    assert policy.plan_values == {"ManagedBy": "terraform"}
    assert {"env", "service", "account"} <= policy.forbidden


def test_policy_values_are_lower_case_kebab(policy):
    for key, values in policy.mandatory.items():
        for v in values:
            assert re.fullmatch(r"[a-z][a-z0-9-]*", v), (key, v)


def test_every_exempt_type_has_a_reason(policy):
    for rtype, reason in policy.exempt_types.items():
        assert rtype.startswith("aws_") and len(reason) > 40, rtype


def test_policy_with_a_plan_value_outside_its_list_is_refused(tmp_path):
    raw = json.load(open(POLICY_PATH, encoding="utf-8"))
    raw["mandatory"]["ManagedBy"]["plan_value"] = "pulumi"
    bad = tmp_path / "policy.json"
    bad.write_text(json.dumps(raw))
    with pytest.raises(tg.InputError):
        tg.load_policy(str(bad))


# --- find_violations -----------------------------------------------------------------------------------------------


def test_compliant_resource_passes(policy):
    found, counts = tg.find_violations(_plan(_rc("aws_lambda_function.a", dict(GOOD))), policy)
    assert found == [] and counts["checked"] == 1


def test_missing_and_empty_keys_are_reported(policy):
    tags = dict(GOOD)
    del tags["Component"]
    tags["Owner"] = ""
    found, _ = tg.find_violations(_plan(_rc("aws_lambda_function.a", tags)), policy)
    assert sorted(_kinds(found)) == [("missing", "Component"), ("missing", "Owner")]


def test_value_outside_the_list_and_old_spellings_are_refused(policy):
    tags = dict(GOOD, App="CIS", Project="AA-CIS")
    found, _ = tg.find_violations(_plan(_rc("aws_lambda_function.a", tags)), policy)
    assert sorted(_kinds(found)) == [("value", "App"), ("value", "Project")]


def test_managed_by_must_say_terraform_in_a_plan(policy):
    found, _ = tg.find_violations(_plan(_rc("aws_lambda_function.a", dict(GOOD, ManagedBy="manual"))), policy)
    assert _kinds(found) == [("value", "ManagedBy")]
    assert "terraform" in found[0].detail


@pytest.mark.parametrize("key", ["Env", "environment", "app", "Service", "Account", "cost-center"])
def test_duplicate_or_retired_keys_are_refused(policy, key):
    found, _ = tg.find_violations(_plan(_rc("aws_lambda_function.a", dict(GOOD, **{key: "x"}))), policy)
    assert _kinds(found) == [("forbidden", key)]


def test_free_optional_keys_pass_and_issue_must_match(policy):
    ok = dict(GOOD, Name="aa-cis-dev-api", Issue="AA-1004", Pool="workforce")
    assert tg.find_violations(_plan(_rc("aws_lambda_function.a", ok)), policy)[0] == []
    found, _ = tg.find_violations(_plan(_rc("aws_lambda_function.a", dict(GOOD, Issue="S271"))), policy)
    assert _kinds(found) == [("pattern", "Issue")]


def test_unknown_value_counts_as_present(policy):
    tags = dict(GOOD)
    del tags["App"]
    rc = _rc("aws_lambda_function.a", tags, unknown={"tags_all": {"App": True}})
    assert tg.find_violations(_plan(rc), policy)[0] == []


def test_whole_map_unknown_is_a_warning_unless_strict(policy):
    rc = _rc("aws_lambda_function.a", None, unknown={"tags_all": True})
    found, counts = tg.find_violations(_plan(rc), policy)
    assert [v.kind for v in found] == ["unknown"] and counts["checked"] == 1
    assert tg.render(found, counts, strict=False)[1] == 0
    assert tg.render(found, counts, strict=True)[1] == 1


def test_untaggable_deleted_noop_and_other_providers_are_skipped(policy):
    plan = _plan(
        _rc("aws_iam_role_policy.p", None),  # no tags attribute: not taggable
        _rc("aws_lambda_function.gone", {}, actions=("delete",)),
        _rc("aws_lambda_function.same", {}, actions=("no-op",)),
        _rc("aws_lambda_function.read", {}, actions=("read",)),
        _rc("random_password.p", {}, provider="registry.terraform.io/hashicorp/random"),
    )
    found, counts = tg.find_violations(plan, policy)
    assert found == [] and counts["checked"] == 0 and counts["not_taggable"] == 1


def test_all_flag_checks_noop_resources(policy):
    plan = _plan(_rc("aws_lambda_function.same", {}, actions=("no-op",)))
    found, counts = tg.find_violations(plan, policy, include_noop=True)
    assert counts["checked"] == 1 and len(found) == len(GOOD)


def test_create_and_replace_are_checked_and_tags_attribute_is_a_fallback(policy):
    plan = _plan(
        _rc("aws_s3_bucket.new", {}, actions=("create",), rtype="aws_s3_bucket"),
        _rc("aws_sqs_queue.q", {}, actions=("delete", "create"), rtype="aws_sqs_queue", attr="tags"),
    )
    found, counts = tg.find_violations(plan, policy)
    assert counts["checked"] == 2 and {v.address for v in found} == {"aws_s3_bucket.new", "aws_sqs_queue.q"}


def test_exempt_type_is_counted_not_checked(policy):
    assert "aws_s3_object" in policy.exempt_types
    found, counts = tg.find_violations(_plan(_rc("aws_s3_object.zip", {}, rtype="aws_s3_object")), policy)
    assert found == [] and counts["exempt"] == 1


def test_too_many_tags(policy):
    tags = dict(GOOD, **{f"aa:k{i}": "v" for i in range(50)})
    found, _ = tg.find_violations(_plan(_rc("aws_lambda_function.a", tags)), policy)
    assert [v.kind for v in found] == ["too-many"]


@pytest.mark.parametrize("plan", [{}, {"format_version": "1.2"}, {"format_version": "1.2", "resource_changes": {}},
                                  {"format_version": "1.2", "resource_changes": [{"address": "x", "change": {}}]}])
def test_bad_plan_shapes_fail_closed(policy, plan):
    with pytest.raises(tg.InputError):
        tg.find_violations(plan, policy)


def test_identity_store_keys_are_redacted_in_the_report(policy):
    rc = _rc('aws_identitystore_user.this["someone"]', {}, rtype="aws_identitystore_user")
    found, counts = tg.find_violations(_plan(rc), policy)
    text, code = tg.render(found, counts, strict=False)
    assert code == 1 and "someone" not in text and "aws_identitystore_user.this[{key}]" in text


# --- CLI -----------------------------------------------------------------------------------------------------------


def test_cli_ok_fixture_exits_0():
    r = _run(os.path.join(FIXTURES, "plan_tags_ok.json"))
    assert r.returncode == 0, r.stderr
    assert "OK" in r.stdout


def test_cli_bad_fixture_exits_1_and_writes_the_summary(tmp_path):
    summary = tmp_path / "summary.md"
    r = _run(os.path.join(FIXTURES, "plan_tags_bad.json"), "--summary", str(summary))
    assert r.returncode == 1
    text = summary.read_text()
    assert "### Terraform tag guard" in text and "FAILED" in text
    for needle in ("missing Component", "Project='AA-CIS'", "forbidden Env"):
        assert needle in text, needle
    # Only tags are printed, never another attribute (the fixture's function code location stays out).
    assert "s3://" not in text and "placeholder.zip" not in text


def test_cli_missing_file_and_bad_json_exit_2(tmp_path):
    assert _run(str(tmp_path / "nope.json")).returncode == 2
    bad = tmp_path / "bad.json"
    bad.write_text("{not json")
    assert _run(str(bad)).returncode == 2


# --- the Terraform roots carry the standard ------------------------------------------------------------------------

ROOT_DEFAULTS = {
    "accounts/aa365/versions.tf": {"Project", "Environment", "Owner", "ManagedBy", "CostCenter", "DataClassification"},
    "accounts/management/versions.tf": set(GOOD),
    "accounts/acc3-bedrock/versions.tf": set(GOOD),
}


def _map_literal(text: str, start: str) -> dict[str, str]:
    i = text.index(start)
    j = text.index("}", i)
    return dict(re.findall(r'^\s*([A-Za-z]+)\s*=\s*(\S+)\s*$', text[i:j], re.M))


@pytest.mark.parametrize("path", sorted(ROOT_DEFAULTS))
def test_every_root_default_tags_carry_the_mandatory_keys(policy, path):
    with open(os.path.join(REPO_ROOT, path), encoding="utf-8") as fh:
        text = fh.read()
    start = "tag_defaults = {" if "tag_defaults = {" in text else "tags = {"
    tags = _map_literal(text, start)
    assert ROOT_DEFAULTS[path] <= set(tags), (path, set(GOOD) - set(tags))
    assert "Account" not in tags and "Env" not in tags
    for key, raw in tags.items():
        if key in policy.mandatory and raw.startswith('"'):
            assert raw.strip('"') in policy.mandatory[key], (path, key, raw)
    if path.endswith("aa365/versions.tf"):
        # App and Component stay out of the default: a forgotten one must fail the guard, not bill one app.
        assert "App" not in tags and "Component" not in tags
        assert text.count("tags = local.tag_defaults") == 4  # every provider (us-west-1, us-east-1, us-east-2, us-west-2; S274)


def _tf_files(*dirs: str):
    for d in dirs:
        for base, _, files in os.walk(os.path.join(REPO_ROOT, d)):
            if ".terraform" in base:
                continue
            for f in files:
                if f.endswith(".tf"):
                    yield os.path.join(base, f)


def test_no_tag_map_overrides_the_defaults_with_an_old_spelling():
    """Resource tags win over default_tags, so a map that repeats Project / ManagedBy / Service would bring them back."""
    bad = []
    pat = re.compile(r'^\s*(Project|ManagedBy|Service|Account)\s*=\s*"', re.M)
    for path in _tf_files("accounts/aa365", "accounts/management", "accounts/acc3-bedrock", "modules"):
        if path.endswith("versions.tf"):
            continue
        with open(path, encoding="utf-8") as fh:
            for n, line in enumerate(fh, 1):
                if pat.match(line):
                    bad.append(f"{os.path.relpath(path, REPO_ROOT)}:{n}")
    assert bad == []


def test_plan_workflow_runs_the_tag_guard_in_the_required_dev_check():
    with open(PLAN_WF, encoding="utf-8") as fh:
        wf = yaml.safe_load(fh)
    job = wf["jobs"]["terraform-plan"]
    assert job["name"] == "Terraform Plan (dev)"  # the ruleset's required check
    names = [s.get("name", "") for s in job["steps"]]
    steps = {s.get("name", ""): s for s in job["steps"]}
    assert "-out=tfplan" in steps["Terraform Plan"]["run"]
    assert names.index("Terraform Plan") < names.index("Tag guard")
    guard = steps["Tag guard"]
    assert "continue-on-error" not in guard and "if" not in guard
    for needle in ("umask 077", "terraform-bin show -json tfplan", "tools/terraform/tag_guard.py", "trap 'rm -f"):
        assert needle in guard["run"], needle
    mgmt = {s.get("name", ""): s for s in wf["jobs"]["terraform-plan-management"]["steps"]}
    assert "-out=" in mgmt["Terraform Plan (summary only)"]["run"]
    assert "tools/terraform/tag_guard.py" in mgmt["Tag guard (management)"]["run"]
    assert "tag_policy" in mgmt["Changed paths"]["run"]
