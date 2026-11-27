"""AA-1185 scope 8 (S296; S295 audit SA-37): offline guards for the narrowed outbound rules of the per-caller app
security groups (accounts/aa365/app_egress.tf + app_security_groups.tf).

1. One root switch (sg_egress_narrowed, default true); false gives every group back the single all-outbound rule.
2. Every per-caller group takes its outbound rules from local.app_egress (no hand-written all-outbound block left),
   and every group has an entry.
3. Narrowed rules are TCP only, on the inventoried ports: 443 for all, 5432 only for the RDS callers, 6379 only for the
   Redis callers, the SMTP submission ports only for the CRM api.
4. No rule names the RDS or Redis group (that would be a dependency cycle with their ingress lists).
5. Rule descriptions stay within what EC2 accepts (a bad character fails the apply, not the plan).

Run: python3 -m pytest -q tools/terraform/tests/test_aa1185_sg_egress.py
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
AA365 = ROOT / "accounts" / "aa365"
EGRESS = (AA365 / "app_egress.tf").read_text(encoding="utf-8")
SGS = (AA365 / "app_security_groups.tf").read_text(encoding="utf-8")

# The SMTP ports AA-Partner dials (api/app/mail/providers/smtp.py PORTS); change both together.
SMTP_PORTS = {25, 465, 587, 2525}
# EC2 security group rule description: up to 255 characters of a-z A-Z 0-9 space . _ - : / ( ) # , @ [ ] + = & ; { } ! $ *
EC2_RULE_DESCRIPTION = re.compile(r"^[A-Za-z0-9 ._\-:/()#,@\[\]+=&;{}!$*]{1,255}$")


def _code(text: str) -> str:
    return "\n".join(ln.split(" #")[0] for ln in text.splitlines() if not ln.lstrip().startswith("#"))


def _block(text: str, opener: str) -> str:
    m = re.search(rf"^{re.escape(opener)} \{{", text, re.M)
    assert m, f"{opener} not found"
    body = text[m.end():]
    return body[: re.search(r"^\}", body, re.M).start()]


def _groups() -> dict[str, str]:
    code = _code(SGS)
    names = re.findall(r'^resource "aws_security_group" "(\w+)" \{', code, re.M)
    return {n: _block(code, f'resource "aws_security_group" "{n}"') for n in names}


def _rule(name: str) -> str:
    m = re.search(rf"^  {name} = \{{(.*?)^  \}}", _code(EGRESS), re.M | re.S)
    assert m, f"local {name} not found"
    return m.group(1)


def _narrowed() -> dict[str, list[str]]:
    body = re.search(r"app_egress_narrowed = \{(.*?)^  \}", _code(EGRESS), re.M | re.S).group(1)
    return {k: re.findall(r"local\.(egress_\w+)", v) for k, v in re.findall(r"^\s+(\w+)\s+= (.+)$", body, re.M)}


def _ports(rule: str) -> tuple[str, str, str]:
    body = _rule(rule)
    return (re.search(r'protocol\s+= "([^"]+)"', body).group(1),
            re.search(r"from_port\s+= (\w+)", body).group(1),
            re.search(r"to_port\s+= (\w+)", body).group(1))


def _ingress_list(name: str) -> list[str]:
    return re.findall(r"aws_security_group\.(\w+)\.id", re.search(rf"{name} = \[(.*?)\]", SGS, re.S).group(1))


def test_one_switch_defaults_to_narrowed_and_rolls_back_to_all_outbound():
    var = _block(EGRESS, 'variable "sg_egress_narrowed"')
    assert "type        = bool" in var and "default     = true" in var
    assert re.search(r"var\.sg_egress_narrowed \? rules : \[local\.egress_all\]", EGRESS)
    assert _ports("egress_all") == ("-1", "0", "0")
    assert '["0.0.0.0/0"]' in _rule("egress_all")


def test_every_group_takes_its_rules_from_app_egress():
    groups = _groups()
    assert set(groups) == set(_narrowed()), "every per-caller group needs an app_egress_narrowed entry and back"
    for name, body in groups.items():
        assert f"for_each = local.app_egress.{name}" in body, name
        assert '"-1"' not in body, f"{name}: hand-written all-protocols rule left"
        assert body.count('dynamic "egress"') == 1, name


def test_narrowed_rules_are_tcp_on_the_inventoried_ports_only():
    rds = set(_ingress_list("rds_ingress_sg_ids"))
    redis = set(_ingress_list("redis_ingress_sg_ids"))
    for caller, rules in _narrowed().items():
        assert "egress_all" not in rules
        assert rules[0] == "egress_https", f"{caller}: 443 out is the first rule of every caller"
        assert ("egress_postgres" in rules) == (caller in rds), caller
        assert ("egress_redis" in rules) == (caller in redis), caller
        assert ("egress_smtp" in rules) == (caller == "crm_api"), caller
    assert _ports("egress_https") == ("tcp", "443", "443")
    assert _ports("egress_postgres") == ("tcp", "5432", "5432")
    assert _ports("egress_redis") == ("tcp", "6379", "6379")
    smtp = re.search(r"egress_smtp = \[for port in \[([\d, ]+)\]", EGRESS).group(1)
    assert {int(p) for p in smtp.split(",")} == SMTP_PORTS
    assert re.search(r'egress_smtp = \[for port in .*?protocol\s+= "tcp"', EGRESS, re.S)


def test_data_store_rules_use_subnet_cidrs_not_the_data_store_groups():
    assert "cidr_blocks = var.db_subnet_cidrs" in _rule("egress_postgres")
    assert "cidr_blocks = var.private_subnet_cidrs" in _rule("egress_redis")
    code = _code(EGRESS) + _code(SGS)
    assert "sg_rds_id" not in code and "module.elasticache" not in code


def test_rule_descriptions_are_valid_for_ec2():
    descriptions = re.findall(r'description = "([^"]*)"', _code(EGRESS))
    assert len(descriptions) >= 6
    for text in descriptions:
        text = text.replace("${port}", "2525")
        assert EC2_RULE_DESCRIPTION.match(text), text
