"""AA-1185 (S296; S295 security audit SA-57): offline guards for the removal of the legacy shared app security group.

1. modules/vpc no longer declares the shared app group (`aa-cis-dev-sg-app`, every port from the ALB, all outbound) and
   no longer outputs its id.
2. Nothing falls back to it any more: the RDS and Redis ingress lists and the CIS api / worker groups are required
   inputs, so a caller left without its own group fails at plan instead of silently landing on a wide group.
3. The data stores still admit exactly the per-caller groups of ADR 0004b.

Run: python3 -m pytest -q tools/terraform/tests/test_aa1185_legacy_app_sg.py
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
AA365 = ROOT / "accounts" / "aa365"
MODULES = ROOT / "modules"


def _code(text: str) -> str:
    """The text without comment lines and trailing comments (no '#' inside the strings these files hold)."""
    return "\n".join(ln.split(" #")[0] for ln in text.splitlines() if not ln.lstrip().startswith("#"))


def _block(text: str, opener: str) -> str:
    m = re.search(rf"^{re.escape(opener)} \{{", text, re.M)
    assert m, f"{opener} not found"
    body = text[m.end():]
    return body[: re.search(r"^\}", body, re.M).start()]


def _all_tf() -> dict[Path, str]:
    return {p: _code(p.read_text(encoding="utf-8")) for p in [*AA365.glob("*.tf"), *MODULES.rglob("*.tf")]}


def test_the_shared_app_group_is_gone():
    vpc = _code((MODULES / "vpc" / "main.tf").read_text(encoding="utf-8"))
    assert 'resource "aws_security_group" "app"' not in vpc
    assert '-sg-app"' not in vpc
    assert 'output "sg_app_id"' not in (MODULES / "vpc" / "outputs.tf").read_text(encoding="utf-8")


def test_no_terraform_code_reads_the_shared_app_group():
    hits = [str(p.relative_to(ROOT)) for p, text in _all_tf().items()
            if re.search(r"\bsg_app_id\b|aws_security_group\.app\b|\bapp_shared\b", text)]
    assert hits == [], f"still reading the removed shared app group: {hits}"


def test_data_store_and_cis_service_groups_are_required_inputs():
    vpc_var = _block((MODULES / "vpc" / "variables.tf").read_text(encoding="utf-8"), 'variable "rds_ingress_sg_ids"')
    cache_var = _block((MODULES / "elasticache" / "variables.tf").read_text(encoding="utf-8"),
                       'variable "ingress_sg_ids"')
    ecs_vars = (MODULES / "ecs" / "variables.tf").read_text(encoding="utf-8")
    for body in (vpc_var, cache_var, _block(ecs_vars, 'variable "sg_api_id"'),
                 _block(ecs_vars, 'variable "sg_worker_id"')):
        assert "default" not in body, "a missing per-caller group must fail at plan, not fall back"
    for body in (vpc_var, cache_var):
        assert "length(var." in body and "> 0" in body

    ecs = _code((MODULES / "ecs" / "main.tf").read_text(encoding="utf-8"))
    assert "security_groups  = [var.sg_api_id]" in ecs
    assert "security_groups  = [var.sg_worker_id]" in ecs
    assert "coalesce(var.sg_" not in ecs


def test_data_stores_admit_exactly_the_per_caller_groups():
    sgs = (AA365 / "app_security_groups.tf").read_text(encoding="utf-8")
    rds = re.search(r"rds_ingress_sg_ids = \[(.*?)\]", sgs, re.S).group(1)
    redis = re.search(r"redis_ingress_sg_ids = \[(.*?)\]", sgs, re.S).group(1)
    assert re.findall(r"aws_security_group\.(\w+)\.id", rds) == [
        "cis_api", "cis_worker", "booking_api", "crm_api", "tp_lambda", "db_migrate"]
    assert re.findall(r"aws_security_group\.(\w+)\.id", redis) == ["cis_api", "cis_worker"]

    main = _code((AA365 / "main.tf").read_text(encoding="utf-8"))
    assert "rds_ingress_sg_ids" in _block(main, 'module "vpc"')
    assert "ingress_sg_ids     = local.redis_ingress_sg_ids" in _block(main, 'module "elasticache"')
