"""WAFv2 descriptions must match the AWS API pattern (S272, AA-1038).

The first apply of the TripPlanner web ACL failed at CreateWebACL because its description held parentheses: the WAFv2
API accepts only word characters, spaces and + = : # @ / - , . in a description, and terraform plan does not check
it. This test reads every aws_wafv2_* resource of the repo and checks each literal description against that pattern.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]

# CreateWebACL / CreateIPSet / CreateRegexPatternSet / CreateRuleGroup: Description pattern and length (1..256).
AWS_DESCRIPTION = re.compile(r"^[\w+=:#@/\-,.][\w+=:#@/\-,.\s]+[\w+=:#@/\-,.]$")
WAF_RESOURCE = re.compile(r'^resource\s+"aws_wafv2_(web_acl|ip_set|regex_pattern_set|rule_group)"\s+"([^"]+)"', re.M)
DESCRIPTION = re.compile(r'^\s{2}description\s*=\s*"((?:[^"\\]|\\.)*)"', re.M)


def _blocks():
    for tf in sorted(list((ROOT / "accounts").rglob("*.tf")) + list((ROOT / "modules").rglob("*.tf"))):
        if ".terraform" in tf.parts:
            continue
        text = tf.read_text(encoding="utf-8")
        starts = [m for m in WAF_RESOURCE.finditer(text)]
        for m in starts:
            end = text.find("\nresource ", m.end())
            yield tf.relative_to(ROOT), f"{m.group(1)}.{m.group(2)}", text[m.end(): end if end != -1 else len(text)]


def test_every_wafv2_description_matches_the_aws_pattern():
    seen = 0
    bad = []
    for path, name, body in _blocks():
        d = DESCRIPTION.search(body)
        if not d or "${" in d.group(1):
            continue
        seen += 1
        value = d.group(1)
        if not (1 <= len(value) <= 256 and AWS_DESCRIPTION.match(value)):
            bad.append(f"{path} {name}: {value!r}")
    assert seen >= 1, "no aws_wafv2_* description found: the scan is broken"
    assert not bad, "WAFv2 descriptions the API refuses:\n" + "\n".join(bad)


def test_the_pattern_refuses_parentheses_and_accepts_the_fixed_text():
    assert not AWS_DESCRIPTION.match("Challenge on the planner (AA-1038)")
    assert AWS_DESCRIPTION.match("TripPlanner web on CloudFront: rate per viewer IP, model paths, Challenge on the planner, AA-1038")
