"""Tests of tools/terraform/alb_rule_order.py (AA-931, v2.2 V3). Offline, stdlib + pytest."""
from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import alb_rule_order as aro  # noqa: E402

REPO = Path(__file__).resolve().parents[3]

PRIORITIES = """
locals {
  alb_origin_header_name = "X-AA-Origin"
  alb_http_rule_priorities = {
    partner = 10 # comment
    deny    = 20
    booking = 100
  }
}
"""

PARTNER = """
resource "aws_lb_listener_rule" "partner" {
  listener_arn = module.alb.http_listener_arn
  priority     = local.alb_http_rule_priorities.partner
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.x.arn
  }
  condition {
    host_header {
      values = ["partner-dev.${var.zone}"]
    }
  }
  condition {
    http_header {
      http_header_name = local.alb_origin_header_name
      values           = [random_password.x[0].result]
    }
  }
}
"""

DENY = """
resource "aws_lb_listener_rule" "deny" {
  listener_arn = module.alb.http_listener_arn
  priority     = local.alb_http_rule_priorities.deny
  action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      status_code  = "403"
    }
  }
  condition {
    http_header {
      http_header_name = local.alb_origin_header_name
      values           = ["*"]
    }
  }
}
"""

BOOKING = """
resource "aws_lb_listener_rule" "booking" {
  listener_arn = module.alb.http_listener_arn
  priority     = local.alb_http_rule_priorities.booking # 100 { not a brace that counts }
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.booking.arn
  }
  condition {
    path_pattern {
      values = ["/booking", "/booking/*"]
    }
  }
}
"""


def _root(tmp_path: Path, **files: str) -> Path:
    for name, text in files.items():
        (tmp_path / f"{name}.tf").write_text(text, encoding="utf-8")
    return tmp_path


def _errors(tmp_path: Path, **files: str) -> list[str]:
    return aro.run(_root(tmp_path, **files), None).errors


def test_repo_source_passes():
    report = aro.run(REPO / "accounts" / "aa365", None)
    assert report.ok, report.errors
    kinds = {r.name.split(":")[1]: r.origin_kind for r in report.rules}
    assert kinds["crm_origin_deny"] == "wildcard"
    assert kinds["crm_partner_default"] == "exact"
    assert kinds["crm_api"] == "exact"
    actions = {r.name.split(":")[1]: (r.action, r.status_code) for r in report.rules}
    # AA-935: the partner host's default forwards to the CRM web (was a fixed 404 JSON, AA-933).
    assert actions["crm_partner_default"][0] == "forward"
    assert kinds["booking"] == "none"


def test_good_order_passes(tmp_path):
    assert _errors(tmp_path, a=PRIORITIES, b=PARTNER + DENY, c=BOOKING) == []


def test_deny_after_booking_fails(tmp_path):
    prio = PRIORITIES.replace("deny    = 20", "deny    = 120")
    errs = _errors(tmp_path, a=prio, b=PARTNER + DENY, c=BOOKING)
    assert any(e.startswith("R4 ") and "booking" in e for e in errs)


def test_partner_after_deny_fails(tmp_path):
    prio = PRIORITIES.replace("partner = 10", "partner = 30")
    errs = _errors(tmp_path, a=prio, b=PARTNER + DENY, c=BOOKING)
    assert any(e.startswith("R3 ") and "below the deny rule" in e for e in errs)


def test_partner_fixed_response_passes(tmp_path):
    """AA-933: the partner host's default may answer a fixed 404 instead of forwarding (until the CRM web)."""
    fixed = PARTNER.replace(
        '    type             = "forward"\n    target_group_arn = aws_lb_target_group.x.arn\n',
        '    type = "fixed-response"\n    fixed_response {\n      content_type = "application/json"\n'
        '      status_code  = "404"\n    }\n',
    )
    assert 'type = "fixed-response"' in fixed
    assert _errors(tmp_path, a=PRIORITIES, b=fixed + DENY, c=BOOKING) == []


def test_partner_redirect_fails(tmp_path):
    redirect = PARTNER.replace('type             = "forward"', 'type             = "redirect"')
    errs = _errors(tmp_path, a=PRIORITIES, b=redirect + DENY, c=BOOKING)
    assert any(e.startswith("R3 ") and "must forward or answer a fixed response" in e for e in errs)


def test_header_rule_without_deny_fails(tmp_path):
    prio = PRIORITIES.replace("    deny    = 20\n", "")
    errs = _errors(tmp_path, a=prio, b=PARTNER, c=BOOKING)
    assert any(e.startswith("R5 ") for e in errs)


def test_partner_rule_without_host_fails(tmp_path):
    no_host = PARTNER.replace(
        '  condition {\n    host_header {\n      values = ["partner-dev.${var.zone}"]\n    }\n  }\n', ""
    )
    errs = _errors(tmp_path, a=PRIORITIES, b=no_host + DENY, c=BOOKING)
    assert any("must also match a host header" in e for e in errs)


def test_deny_must_be_403(tmp_path):
    errs = _errors(tmp_path, a=PRIORITIES, b=PARTNER + DENY.replace('"403"', '"404"'), c=BOOKING)
    assert any(e.startswith("R2 ") for e in errs)


def test_literal_priority_fails(tmp_path):
    lit = BOOKING.replace("local.alb_http_rule_priorities.booking", "100")
    prio = PRIORITIES.replace("    booking = 100\n", "")
    errs = _errors(tmp_path, a=prio, b=PARTNER + DENY, c=lit)
    assert any(e.startswith("S1 ") and "must be local." in e for e in errs)


def test_duplicate_map_value_and_stale_key_fail(tmp_path):
    prio = PRIORITIES.replace("booking = 100", "booking = 20\n    spare = 300")
    errs = _errors(tmp_path, a=prio, b=PARTNER + DENY, c=BOOKING)
    assert any("priority 20 used by more than one key" in e for e in errs)
    assert any("spare" in e and "not used" in e for e in errs)


def test_other_listener_ignored(tmp_path):
    other = BOOKING.replace("module.alb.http_listener_arn", "module.alb.https_listener_arn").replace(
        "local.alb_http_rule_priorities.booking", "5"
    )
    prio = PRIORITIES.replace("    booking = 100\n", "")
    assert _errors(tmp_path, a=prio, b=PARTNER + DENY, c=other) == []


def _live(*rules: dict) -> dict:
    return {"Rules": list(rules)}


def _r(prio, conds, action):
    return {"RuleArn": f"arn:x/listener-rule/app/alb/1/2/r{prio}", "Priority": str(prio), "IsDefault": prio == "default",
            "Conditions": conds, "Actions": [action]}


HOST = {"Field": "host-header", "HostHeaderConfig": {"Values": ["partner-dev.example"]}}
SECRET = {"Field": "http-header", "HttpHeaderConfig": {"HttpHeaderName": "X-AA-Origin", "Values": ["s3cr3tvalue"]}}
ANY = {"Field": "http-header", "HttpHeaderConfig": {"HttpHeaderName": "x-aa-origin", "Values": ["*"]}}
PATH = {"Field": "path-pattern", "PathPatternConfig": {"Values": ["/booking/*"]}}
FWD = {"Type": "forward", "TargetGroupArn": "tg"}
F403 = {"Type": "fixed-response", "FixedResponseConfig": {"StatusCode": "403"}}
F404 = {"Type": "fixed-response", "FixedResponseConfig": {"StatusCode": "404", "ContentType": "application/json"}}
PATH_CRM = {"Field": "path-pattern", "PathPatternConfig": {"Values": ["/crm", "/crm/*"]}}


def test_live_good(tmp_path, capsys):
    f = tmp_path / "rules.json"
    f.write_text(json.dumps(_live(_r(10, [HOST, SECRET], FWD), _r(20, [ANY], F403), _r(100, [PATH], FWD),
                                  _r("default", [], FWD))))
    assert aro.main(["--live", str(f)]) == 0
    out = capsys.readouterr()
    assert "s3cr3tvalue" not in out.out + out.err  # never print header values


def test_live_partner_default_404(tmp_path, capsys):
    """AA-933 shape: crm_api (5) forwards /crm/*, crm_partner_default (10) answers 404, deny (20), Booking (100)."""
    f = tmp_path / "rules.json"
    f.write_text(json.dumps(_live(_r(5, [HOST, SECRET, PATH_CRM], FWD), _r(10, [HOST, SECRET], F404),
                                  _r(20, [ANY], F403), _r(100, [PATH], FWD), _r("default", [], FWD))))
    assert aro.main(["--live", str(f)]) == 0
    out = capsys.readouterr()
    assert "s3cr3tvalue" not in out.out + out.err


def test_live_bad_order(tmp_path, capsys):
    f = tmp_path / "rules.json"
    f.write_text(json.dumps(_live(_r(10, [PATH], FWD), _r(20, [ANY], F403), _r(30, [HOST, SECRET], FWD),
                                  _r("default", [], FWD))))
    assert aro.main(["--live", str(f)]) == 1
    out = capsys.readouterr()
    assert "R3 " in out.err and "R4 " in out.err
    assert "s3cr3tvalue" not in out.out + out.err


def test_live_bad_input(tmp_path):
    f = tmp_path / "rules.json"
    f.write_text("{}")
    assert aro.main(["--live", str(f)]) == 2


def test_comment_and_string_braces_do_not_break_parsing():
    text = aro._strip_comments('a = "x { y" # } z\nb { c = "}" }\n')
    assert "z" not in text
    start = text.index("b {") + 2
    assert text[aro._block_end(text, start)] == "}"


@pytest.mark.parametrize("values,kind", [(None, "none"), (["*"], "wildcard"), (["abc"], "exact"), (["a*"], "pattern")])
def test_origin_kind(values, kind):
    assert aro.Rule("r", 1, "forward", origin_values=values).origin_kind == kind
