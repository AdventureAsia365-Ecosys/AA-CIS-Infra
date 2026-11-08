"""No WAF rule nests logical statements deeper than 3 levels (S272, AA-1038).

The AWS provider schema allows only a few nested and_statement / or_statement / not_statement levels below a rule's
statement. TripPlannerChallengePlanner once nested and > or > and > or (4 levels): `terraform validate` passed because
the rule is a dynamic block whose for_each is unknown there, and the CI plan then failed with
'Blocks of type "or_statement" are not expected here'. This test reads modules/waf/main.tf, walks every rule of the
web ACL (static `rule` blocks and the `content` of `dynamic "rule"` blocks) and fails when a rule nests logical
statements deeper than MAX_DEPTH, counting every and/or/not block from the rule statement down (a rate rule's
scope_down_statement included). A deeper match goes into one regex_match_statement instead.

Offline: reads the .tf file; no Terraform, no AWS. Run from the repo root:
    python3 -m pytest -p no:cacheprovider -q tools/terraform/tests/test_waf_statement_depth.py
"""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
WAF = ROOT / "modules" / "waf" / "main.tf"

MAX_DEPTH = 3
LOGICAL = {"and_statement", "or_statement", "not_statement"}
_STRING = re.compile(r'"(?:[^"\\]|\\.)*"')
_BLOCK_HEAD = re.compile(r'(\w+)((?:\s+"[^"]*")*)\s*$')
_RULE_NAME = re.compile(r'^\s*name\s*=\s*"([^"]+)"')


def _strip_comment(line: str) -> str:
    """The line without a trailing # or // comment (a # inside a string is kept)."""
    out, i = [], 0
    while i < len(line):
        m = _STRING.match(line, i)
        if m:
            out.append(m.group(0))
            i = m.end()
            continue
        if line[i] == "#" or line.startswith("//", i):
            break
        out.append(line[i])
        i += 1
    return "".join(out)


def rule_depths(text: str) -> dict[str, int]:
    """{rule name: deepest run of nested logical statements} for every rule block of the text."""
    stack: list[str] = []  # block names, e.g. "dynamic:rule", "content", "and_statement"
    rule_at: int | None = None  # stack index of the current rule block
    current = ""
    depths: dict[str, int] = {}
    for raw in text.splitlines():
        line = _strip_comment(raw)
        if rule_at is not None and len(stack) == rule_at + 1:
            m = _RULE_NAME.match(line)
            if m:
                current = m.group(1)
                depths.setdefault(current, 0)
        # Walk the braces outside strings; the block name is the word (plus labels) just before each "{".
        i = 0
        while i < len(line):
            m = _STRING.match(line, i)
            if m:
                i = m.end()
                continue
            ch = line[i]
            if ch == "{":
                head = _BLOCK_HEAD.search(line[:i])
                name = "?"
                if head:
                    labels = re.findall(r'"([^"]*)"', head.group(2))
                    name = head.group(1) + (":" + labels[0] if labels else "")
                is_rule = name == "rule" or (name == "content" and stack and stack[-1] == "dynamic:rule")
                stack.append(name)
                if is_rule and rule_at is None:
                    rule_at = len(stack) - 1
                    current = ""
                elif rule_at is not None and name in LOGICAL:
                    level = sum(1 for n in stack[rule_at + 1 :] if n in LOGICAL)
                    key = current or f"<unnamed rule at stack {rule_at}>"
                    depths[key] = max(depths.get(key, 0), level)
            elif ch == "}":
                assert stack, "unbalanced braces"
                stack.pop()
                if rule_at is not None and len(stack) == rule_at:
                    rule_at = None
            i += 1
    assert not stack, "unbalanced braces"
    return depths


def test_every_waf_rule_nests_logical_statements_at_most_three_deep():
    depths = rule_depths(WAF.read_text(encoding="utf-8"))
    # Every rule of the ACL is seen (a parse miss must not pass silently).
    for name in [
        "AWSManagedRulesCommonRuleSet", "TripPlannerRateLimitPerIp", "TripPlannerRateLimitModelPaths",
        "TripPlannerChallengePlanner", "VpcLinkInternalAllow", "CloudFrontOriginAllow", "RateLimit1000",
        "GeoBlockNonAllowed", "StaffWebRateLimit",
    ]:
        assert name in depths, (name, sorted(depths))
    too_deep = {name: d for name, d in depths.items() if d > MAX_DEPTH}
    assert not too_deep, f"logical statements nested deeper than {MAX_DEPTH}: {too_deep}"
    # The challenge rule is the deepest one today (and > or > and); the parser must see it.
    assert depths["TripPlannerChallengePlanner"] == 3
    assert depths["GeoBlockNonAllowed"] == 1


_FOUR_DEEP = """
resource "aws_wafv2_web_acl" "main" {
  # a comment with { braces } and_statement {
  dynamic "rule" {
    for_each = [1]
    content {
      name = "TooDeep"
      statement {
        and_statement {
          statement {
            or_statement {
              statement {
                and_statement {
                  statement {
                    or_statement {
                      statement {
                        byte_match_statement {
                          search_string = "x{y}"
                          field_to_match {
                            uri_path {}
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
  rule {
    name = "Flat"
    statement {
      rate_based_statement {
        scope_down_statement {
          not_statement {
            statement {
              geo_match_statement {}
            }
          }
        }
      }
    }
  }
  tags = merge(var.tags, {
    Module = "waf"
  })
}
"""


def test_the_parser_catches_the_four_level_shape_that_failed_the_plan():
    depths = rule_depths(_FOUR_DEEP)
    assert depths == {"TooDeep": 4, "Flat": 1}
