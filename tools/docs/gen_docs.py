#!/usr/bin/env python3
"""Generated infrastructure docs for the AA-Ecosys root repo (AA-893).

Renders four reference pages from a Terraform JSON document of accounts/aa365 — the state
(`terraform show -json`, what the docs-gen workflow uses) or a saved plan
(`terraform show -json tfplan`, its planned values; handy to preview a branch):

  alarms.md     OPS-07           every aws_cloudwatch_metric_alarm and every EventBridge rule that
                                 notifies an SNS topic: name, app, condition, topic, runbook link
  network.md    ARCH-02-tables   VPC, subnets, route tables, NAT, security groups, load balancers,
                                 API Gateway, DNS records
  inventory.md  ARCH-03          resources per App tag, plus the root outputs (non-sensitive only)
  iam-roles.md  ARCH-04-tables   IAM roles: trust, boundary, managed and inline policies (actions)

The pages land in the root repo at docs/generated/ through a bot PR (.github/workflows/docs-gen.yml).
Nobody edits them by hand: change the Terraform and the next run updates the page.

Safety: the state and plan JSON hold secret values in clear text (secret versions, random_password,
the RDS password). This script reads an explicit list of attributes per resource type, never prints
the input, and renders an output only when Terraform does not mark it sensitive.

Public repos (AA-981, S248 d15): every page goes through tools/docs/aws_mask.py before it is written
(account ids -> `{acc2}` labels from env AWS_ACCOUNT_ALIASES, ARNs -> `arn:{partition}:...` without
the account, Secrets Manager suffixes dropped, EC2/VPC ids -> `<prefix>-{masked}`), and `page()`
refuses to return a page in which aws_mask.find_leaks still finds one.

Runbook links: every alarm description (and SNS-notifying rule description) ends with
" Runbook: <url>" (accounts/aa365/alarm_runbooks.tf). The URL must point into the root repo's docs/
(blob/master); the page renders it as a relative link, which the root docs lint (lychee +
tools/docs/check_alarm_runbooks.py there) resolves. With --root-dir the file must also exist in that
checkout. A missing or unresolvable link is a problem: `render` lists problems as ::error lines and
in --problems-file, and exits 1 with --strict.

Subcommands (stdlib only):
  render        --tf-json FILE --out-dir DIR [--root-dir ROOT] [--source TEXT] [--sha SHA]
                [--date YYYY-MM-DD] [--problems-file FILE] [--strict]
  changed       --new DIR --old DIR [--max-age-days N] [--date YYYY-MM-DD]
                prints the page names whose content fingerprint differs from the old copy, or
                whose old copy is missing or older than N days (keeps last_reviewed fresh); also
                covers EXTRA_PAGES rendered by sibling generators (env-config.md, gen_env_config.py)
  check-source  DIR...   every alarm / SNS-notifying EventBridge rule in the .tf files under DIR
                carries a runbook suffix (offline guard for pull requests)
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import posixpath
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable, Iterator, Mapping, Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # aws_mask sits next to this file
import aws_mask  # noqa: E402

ROOT_REPO_BLOB_PREFIX = "https://github.com/AdventureAsia365-Ecosys/AA-Ecosys/blob/master/"
GENERATED_DIR = "docs/generated"  # in the root repo
GENERATOR = "infra/AA-CIS-Infra/.github/workflows/docs-gen.yml"
RUNBOOK_RE = re.compile(r"\s*Runbook:\s*(\S+)\s*$")
FINGERPRINT_RE = re.compile(r"<!-- docs-fingerprint: ([0-9a-f]{64}) -->")
LAST_REVIEWED_RE = re.compile(r"^last_reviewed:\s*(\d{4}-\d{2}-\d{2})\s*$", re.M)

PAGES = ("alarms.md", "network.md", "inventory.md", "iam-roles.md")
# Pages rendered by sibling generators into the same out dir and published by the same bot PR:
# env-config.md (gen_env_config.py, AA-894 scope 5). `changed` considers them too.
EXTRA_PAGES = ("env-config.md",)

# Sub-resources listed only as counts in the inventory (they are configuration of a parent).
INVENTORY_DETAIL_TYPES = frozenset(
    {
        "aws_api_gateway_integration",
        "aws_api_gateway_method",
        "aws_api_gateway_method_settings",
        "aws_api_gateway_resource",
        "aws_api_gateway_base_path_mapping",
        "aws_apigatewayv2_integration",
        "aws_apigatewayv2_route",
        "aws_apigatewayv2_api_mapping",
        "aws_acm_certificate_validation",
        "aws_cloudwatch_event_target",
        "aws_ecr_lifecycle_policy",
        "aws_efs_mount_target",
        "aws_eip_association",
        "aws_iam_role_policy",
        "aws_iam_role_policy_attachment",
        "aws_lambda_permission",
        "aws_lb_listener_rule",
        "aws_lb_target_group_attachment",
        "aws_route53_record",
        "aws_route_table_association",
        "aws_s3_bucket_cors_configuration",
        "aws_s3_bucket_lifecycle_configuration",
        "aws_s3_bucket_ownership_controls",
        "aws_s3_bucket_policy",
        "aws_s3_bucket_public_access_block",
        "aws_s3_bucket_server_side_encryption_configuration",
        "aws_s3_bucket_versioning",
        "aws_s3_object",
        "aws_secretsmanager_secret_policy",
        "aws_secretsmanager_secret_version",
        "aws_sesv2_configuration_set_event_destination",
        "aws_sns_topic_policy",
        "aws_sqs_queue_policy",
        "aws_wafv2_web_acl_association",
        "aws_wafv2_web_acl_logging_configuration",
        "random_password",
        "time_sleep",
    }
)

# Attributes that may name a resource in the inventory, in order of preference. Never a value
# attribute (secret_string, result, password, policy bodies).
NAME_ATTRS = (
    "alarm_name",
    "function_name",
    "identifier",
    "cluster_id",
    "bucket",
    "domain_name",
    "email_identity",
    "configuration_set_name",
    "name",
)


class InputError(Exception):
    """The input is not a Terraform state or plan JSON (exit 2, fail closed)."""


# --------------------------------------------------------------------------- input


@dataclass
class Resource:
    address: str
    type: str
    name: str
    values: dict

    @property
    def tags(self) -> dict:
        tags = self.values.get("tags") or {}
        if not tags:
            tags = self.values.get("tags_all") or {}
        return tags if isinstance(tags, dict) else {}

    @property
    def app(self) -> str:
        return str(self.tags.get("App") or "")


@dataclass
class TfDoc:
    kind: str  # "state" or "plan"
    resources: list[Resource]
    outputs: dict  # name -> {"value": ..., "sensitive": bool}

    def of_type(self, *types: str) -> list[Resource]:
        return sorted((r for r in self.resources if r.type in types), key=lambda r: r.address)


def _walk(module: dict) -> Iterator[dict]:
    for res in module.get("resources") or []:
        yield res
    for child in module.get("child_modules") or []:
        yield from _walk(child)


def load_tf_json(path: Path) -> TfDoc:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise InputError(f"cannot read {path}: {exc.__class__.__name__}") from None
    if not isinstance(data, dict) or "format_version" not in data:
        raise InputError(f"{path} is not a Terraform JSON document (no format_version)")
    if "planned_values" in data:
        kind, values = "plan", data.get("planned_values") or {}
    elif "values" in data:
        kind, values = "state", data.get("values") or {}
    else:
        raise InputError(f"{path} has neither values (state) nor planned_values (plan)")
    root = values.get("root_module") or {}
    resources = [
        Resource(r.get("address", ""), r.get("type", ""), r.get("name", ""), r.get("values") or {})
        for r in _walk(root)
        if r.get("mode") == "managed"
    ]
    outputs = values.get("outputs") or {}
    return TfDoc(kind, resources, outputs if isinstance(outputs, dict) else {})


# --------------------------------------------------------------------------- helpers


def cell(text: Any) -> str:
    """One Markdown table cell: no newline, pipes escaped."""
    if text is None:
        return ""
    s = str(text).replace("\r", " ").replace("\n", " ").strip()
    return s.replace("|", "\\|")


def code(text: Any) -> str:
    s = cell(text)
    return Raw(f"`{s}`") if s else ""


def table(headers: list[str], rows: list[list[Any]]) -> str:
    out = ["| " + " | ".join(headers) + " |", "|" + "|".join("---" for _ in headers) + "|"]
    for row in rows:
        out.append("| " + " | ".join(cell(c) if not isinstance(c, Raw) else str(c) for c in row) + " |")
    return "\n".join(out)


class Raw(str):
    """A table cell that is already Markdown (links, code spans), its parts escaped by the caller."""

    def __new__(cls, value: str):
        return super().__new__(cls, str(value).replace("\r", " ").replace("\n", " "))


def arn_name(arn: str) -> str:
    """Last segment of an ARN (topic, role or policy name)."""
    if not arn:
        return ""
    tail = arn.split(":")[-1]
    return tail.split("/")[-1] if arn.startswith("arn:aws:iam::") else tail


def duration(seconds: Any) -> str:
    try:
        s = int(seconds)
    except (TypeError, ValueError):
        return str(seconds)
    if s and s % 86400 == 0:
        return f"{s // 86400} d"
    if s and s % 3600 == 0:
        return f"{s // 3600} h"
    if s and s % 60 == 0:
        return f"{s // 60} min"
    return f"{s} s"


def number(v: Any) -> str:
    if isinstance(v, float) and v.is_integer():
        return str(int(v))
    return str(v)


def resource_name(r: Resource) -> str:
    for attr in NAME_ATTRS:
        v = r.values.get(attr)
        if isinstance(v, str) and v:
            return v
    name_tag = r.tags.get("Name")
    if name_tag:
        return str(name_tag)
    rid = r.values.get("id")
    return str(rid) if isinstance(rid, str) else ""


# --------------------------------------------------------------------------- runbooks


@dataclass
class Problems:
    items: list[str] = field(default_factory=list)

    def add(self, msg: str) -> None:
        self.items.append(msg)


def split_runbook(description: str) -> tuple[str, Optional[str]]:
    description = description or ""
    m = RUNBOOK_RE.search(description)
    if not m:
        return description.strip(), None
    return description[: m.start()].rstrip(), m.group(1)


def runbook_cell(owner: str, url: Optional[str], root_dir: Optional[Path], problems: Problems) -> Raw:
    """Relative link from docs/generated/ to the runbook, after checking it resolves."""
    if not url:
        problems.add(f"{owner}: no ' Runbook: <url>' suffix in its description")
        return Raw("**MISSING**")
    if not url.startswith(ROOT_REPO_BLOB_PREFIX):
        problems.add(f"{owner}: runbook {url} is not a file in the root repo ({ROOT_REPO_BLOB_PREFIX}...)")
        return Raw(f"**NOT IN ROOT REPO** `{cell(url)}`")
    rel = url[len(ROOT_REPO_BLOB_PREFIX):].split("#", 1)[0]
    norm = posixpath.normpath(rel)
    if norm.startswith("..") or not norm.startswith("docs/") or not norm.endswith(".md"):
        problems.add(f"{owner}: runbook {url} must be a Markdown file under root docs/")
        return Raw(f"**NOT UNDER docs/** `{cell(url)}`")
    if root_dir is not None and not (root_dir / norm).is_file():
        problems.add(f"{owner}: runbook {norm} does not exist in the root repo")
        return Raw(f"**BROKEN** `{norm}`")
    link = posixpath.relpath(norm, GENERATED_DIR)
    return Raw(f"[{cell(norm[len('docs/'):])}]({link})")


# --------------------------------------------------------------------------- alarms

OPERATORS = {
    "GreaterThanThreshold": ">",
    "GreaterThanOrEqualToThreshold": ">=",
    "LessThanThreshold": "<",
    "LessThanOrEqualToThreshold": "<=",
    "LessThanLowerOrGreaterThanUpperThreshold": "outside band",
    "LessThanLowerThreshold": "below band",
    "GreaterThanUpperThreshold": "above band",
}


def _metric_label(namespace: str, metric: str, stat: str, dims: dict) -> str:
    dim = ", ".join(f"{k}={v}" for k, v in sorted((dims or {}).items()))
    return f"{namespace}/{metric} {stat}" + (f" [{dim}]" if dim else "")


def alarm_condition(v: dict) -> str:
    op = OPERATORS.get(v.get("comparison_operator", ""), v.get("comparison_operator", ""))
    threshold = number(v.get("threshold")) if v.get("threshold_metric_id") in (None, "") else f"band {v['threshold_metric_id']}"
    queries = v.get("metric_query") or []
    if queries:
        parts = []
        result = ""
        for q in queries:
            if q.get("expression"):
                label = q.get("label") or q.get("id")
                if q.get("return_data"):
                    result = f"{label} = {q['expression']}"
                else:
                    parts.append(f"{q.get('id')} = {q['expression']}")
            for m in q.get("metric") or []:
                parts.append(
                    f"{q.get('id')} = "
                    + _metric_label(m.get("namespace", ""), m.get("metric_name", ""), m.get("stat", ""), m.get("dimensions"))
                    + f" per {duration(m.get('period'))}"
                )
        what = result or "metric math"
        head = f"{what} {op} {threshold}"
        tail = "; ".join(parts)
        period = ""
    else:
        stat = v.get("statistic") or v.get("extended_statistic") or ""
        head = _metric_label(v.get("namespace", ""), v.get("metric_name", ""), stat, v.get("dimensions")) + f" {op} {threshold}"
        tail = ""
        period = f" per {duration(v.get('period'))}"
    evals = v.get("evaluation_periods") or 1
    dta = v.get("datapoints_to_alarm") or evals
    window = f"{dta} of {evals}" if dta != evals else f"{evals}"
    text = f"{head}{period}, {window} period(s)"
    missing = v.get("treat_missing_data")
    if missing and missing != "missing":
        text += f", missing data: {missing}"
    if tail:
        text += f" ({tail})"
    return text


def actions_text(v: dict) -> str:
    alarm = sorted(arn_name(a) for a in v.get("alarm_actions") or [])
    ok = sorted(arn_name(a) for a in v.get("ok_actions") or [])
    if v.get("actions_enabled") is False:
        prefix = "actions disabled: "
    else:
        prefix = ""
    if alarm and alarm == ok:
        return prefix + ", ".join(alarm) + " (ALARM + OK)"
    parts = []
    if alarm:
        parts.append(", ".join(alarm) + " (ALARM)")
    if ok:
        parts.append(", ".join(ok) + " (OK)")
    return prefix + ("; ".join(parts) if parts else "none")


def _event_names(node: Any) -> list[str]:
    found: list[str] = []
    if isinstance(node, dict):
        for k, val in node.items():
            if k == "eventName" and isinstance(val, list):
                found.extend(str(x) for x in val if isinstance(x, str))
            else:
                found.extend(_event_names(val))
    elif isinstance(node, list):
        for item in node:
            found.extend(_event_names(item))
    return found


def event_summary(v: dict) -> str:
    if v.get("schedule_expression"):
        return f"schedule {v['schedule_expression']}"
    try:
        pattern = json.loads(v.get("event_pattern") or "{}")
    except ValueError:
        return "event pattern (unparsed)"
    sources = ", ".join(pattern.get("source") or [])
    dtypes = ", ".join(pattern.get("detail-type") or [])
    names = sorted(dict.fromkeys(_event_names(pattern.get("detail"))))
    text = sources
    if dtypes:
        text += f" / {dtypes}"
    if names:
        text += ": " + ", ".join(names)
    return text


def render_alarms(doc: TfDoc, root_dir: Optional[Path], problems: Problems) -> str:
    alarms = doc.of_type("aws_cloudwatch_metric_alarm")
    rules = {r.values.get("name"): r for r in doc.of_type("aws_cloudwatch_event_rule")}
    sns_targets: dict[str, list[str]] = {}
    for t in doc.of_type("aws_cloudwatch_event_target"):
        arn = t.values.get("arn") or ""
        if arn.startswith("arn:aws:sns:"):
            sns_targets.setdefault(t.values.get("rule"), []).append(arn_name(arn))

    by_app: dict[str, list[list[Any]]] = {}
    for a in alarms:
        v = a.values
        desc, url = split_runbook(v.get("alarm_description") or "")
        name = v.get("alarm_name") or a.address
        by_app.setdefault(a.app or "untagged", []).append(
            [code(name), alarm_condition(v), actions_text(v), runbook_cell(name, url, root_dir, problems), desc]
        )

    lines = [
        "Every CloudWatch metric alarm and every EventBridge rule that notifies an SNS topic in the acc2 stack",
        "(`accounts/aa365` and its modules). Each row links to the runbook the alarm e-mail names; the link is",
        "the `Runbook:` suffix of the alarm description (AA-CIS-Infra `accounts/aa365/alarm_runbooks.tf`).",
        "Severity and first steps for every alarm: [incident response](../ops/incident-response.md).",
        "",
        f"**Totals:** {len(alarms)} metric alarms, "
        f"{sum(1 for n in rules if n in sns_targets)} EventBridge alarm rules.",
        "",
        "## Metric alarms",
        "",
        "Grouped by the `App` tag (the owning app). Condition: metric and statistic, threshold, evaluation window.",
    ]
    for app in sorted(by_app):
        rows = sorted(by_app[app], key=lambda r: r[0])
        lines += ["", f"### {app}", "", table(["Alarm", "Condition", "Notifies", "Runbook", "What it means"], rows)]

    ev_rows = []
    for name in sorted(n for n in rules if n in sns_targets):
        r = rules[name]
        desc, url = split_runbook(r.values.get("description") or "")
        ev_rows.append(
            [
                code(name),
                r.app or "untagged",
                event_summary(r.values),
                ", ".join(sorted(sns_targets[name])),
                runbook_cell(name, url, root_dir, problems),
                desc,
            ]
        )
    lines += ["", "## EventBridge alarm rules", "", "Rules whose target is an SNS topic (the e-mail is the target's input template)."]
    lines += ["", table(["Rule", "App", "Event", "Notifies", "Runbook", "What it means"], ev_rows) if ev_rows else "None."]
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------- network


def _names_by_id(doc: TfDoc, *types: str) -> dict[str, str]:
    out = {}
    for r in doc.of_type(*types):
        rid = r.values.get("id")
        if isinstance(rid, str):
            out[rid] = resource_name(r)
    return out


def _rule_text(rule: dict, sg_names: dict[str, str]) -> str:
    proto = str(rule.get("protocol") or rule.get("ip_protocol") or "")
    proto = "all" if proto == "-1" else proto
    lo, hi = rule.get("from_port"), rule.get("to_port")
    if proto == "all" or (lo in (0, None) and hi in (0, None, 65535)):
        ports = "" if proto == "all" else " all ports"
    else:
        ports = f" {lo}" if lo == hi else f" {lo}-{hi}"
    peers = list(rule.get("cidr_blocks") or []) + list(rule.get("ipv6_cidr_blocks") or [])
    for key in ("cidr_ipv4", "cidr_ipv6"):
        if rule.get(key):
            peers.append(rule[key])
    sgs = list(rule.get("security_groups") or [])
    for key in ("referenced_security_group_id", "source_security_group_id"):
        if rule.get(key):
            sgs.append(rule[key])
    peers = sorted(peers) + sorted(sg_names.get(s, s) for s in sgs)
    peers += sorted(rule.get("prefix_list_ids") or [])
    if rule.get("self"):
        peers.append("self")
    desc = f" ({rule['description']})" if rule.get("description") else ""
    return f"{proto}{ports} {', '.join(peers) or '-'}{desc}"


def render_network(doc: TfDoc) -> str:
    subnet_names = _names_by_id(doc, "aws_subnet")
    sg_names = _names_by_id(doc, "aws_security_group")
    rt_names = _names_by_id(doc, "aws_route_table")
    lb_by_arn = {r.values.get("arn"): r.values.get("name") for r in doc.of_type("aws_lb")}
    api_names = {r.values.get("id"): r.values.get("name") for r in doc.of_type("aws_api_gateway_rest_api", "aws_apigatewayv2_api")}
    instance_names = _names_by_id(doc, "aws_instance")
    for r in doc.of_type("aws_instance"):  # a route to the NAT instance names its primary ENI
        eni = r.values.get("primary_network_interface_id")
        if isinstance(eni, str):
            instance_names[eni] = f"{resource_name(r)} ({eni})"
    lines = ["Network, edge and DNS of the acc2 stack, from the Terraform state of `accounts/aa365`.", ""]

    vpcs = doc.of_type("aws_vpc")
    lines += ["## VPC", "", table(["Name", "ID", "CIDR"], [[r.tags.get("Name", ""), code(r.values.get("id")), r.values.get("cidr_block")] for r in vpcs])]

    rt_of_subnet = {a.values.get("subnet_id"): a.values.get("route_table_id") for a in doc.of_type("aws_route_table_association")}
    rows = []
    for r in sorted(doc.of_type("aws_subnet"), key=lambda r: resource_name(r)):
        v = r.values
        rows.append(
            [
                resource_name(r),
                code(v.get("id")),
                v.get("availability_zone"),
                v.get("cidr_block"),
                "yes" if v.get("map_public_ip_on_launch") else "no",
                rt_names.get(rt_of_subnet.get(v.get("id")), rt_of_subnet.get(v.get("id")) or ""),
            ]
        )
    lines += ["", "## Subnets", "", table(["Name", "ID", "AZ", "CIDR", "Public IP on launch", "Route table"], rows)]

    rows = []
    for r in doc.of_type("aws_route_table"):
        routes = []
        for route in r.values.get("route") or []:
            dest = route.get("cidr_block") or route.get("ipv6_cidr_block") or route.get("destination_prefix_list_id") or ""
            target = ""
            for key in ("gateway_id", "nat_gateway_id", "network_interface_id", "instance_id", "vpc_endpoint_id", "transit_gateway_id", "vpc_peering_connection_id"):
                if route.get(key):
                    target = f"{key.replace('_id', '')} {instance_names.get(route[key], route[key])}"
                    break
            routes.append(f"{dest} -> {target or 'local'}")
        subnets = sorted(subnet_names.get(s, s) for s, rt in rt_of_subnet.items() if rt == r.values.get("id"))
        rows.append([resource_name(r), code(r.values.get("id")), "; ".join(routes) or "local only", ", ".join(subnets)])
    lines += ["", "## Route tables", "", table(["Name", "ID", "Routes (besides local)", "Subnets"], rows)]

    rows = []
    eips = {e.values.get("instance"): e.values.get("public_ip") for e in doc.of_type("aws_eip")}
    for r in doc.of_type("aws_instance"):
        v = r.values
        rows.append([resource_name(r), code(v.get("id")), v.get("instance_type"), subnet_names.get(v.get("subnet_id"), v.get("subnet_id")), v.get("private_ip"), eips.get(v.get("id"), "")])
    lines += ["", "## EC2 instances (NAT)", "", table(["Name", "ID", "Type", "Subnet", "Private IP", "Elastic IP"], rows) if rows else "None."]

    extra_in: dict[str, list[str]] = {}
    extra_out: dict[str, list[str]] = {}
    for r in doc.of_type("aws_security_group_rule"):
        target = extra_in if r.values.get("type") == "ingress" else extra_out
        target.setdefault(r.values.get("security_group_id"), []).append(_rule_text(r.values, sg_names))
    for r in doc.of_type("aws_vpc_security_group_ingress_rule"):
        extra_in.setdefault(r.values.get("security_group_id"), []).append(_rule_text(r.values, sg_names))
    for r in doc.of_type("aws_vpc_security_group_egress_rule"):
        extra_out.setdefault(r.values.get("security_group_id"), []).append(_rule_text(r.values, sg_names))
    rows = []
    for r in sorted(doc.of_type("aws_security_group"), key=lambda r: resource_name(r)):
        v = r.values
        sid = v.get("id")
        ingress = sorted(_rule_text(x, sg_names) for x in v.get("ingress") or []) + sorted(extra_in.get(sid, []))
        egress = sorted(_rule_text(x, sg_names) for x in v.get("egress") or []) + sorted(extra_out.get(sid, []))
        rows.append([resource_name(r), code(sid), r.app, v.get("description"), "; ".join(ingress) or "none", "; ".join(egress) or "none"])
    lines += ["", "## Security groups", "", "Peers are shown by security group name where the group is in this state.", ""]
    lines += [table(["Name", "ID", "App", "Description", "Ingress", "Egress"], rows)]

    rows = []
    for r in doc.of_type("aws_lb"):
        v = r.values
        rows.append(
            [
                v.get("name"),
                v.get("load_balancer_type"),
                "internal" if v.get("internal") else "internet-facing",
                ", ".join(sorted(subnet_names.get(s, s) for s in v.get("subnets") or [])),
                ", ".join(sorted(sg_names.get(s, s) for s in v.get("security_groups") or [])),
                code(v.get("dns_name")),
            ]
        )
    lines += ["", "## Load balancers", "", table(["Name", "Type", "Scheme", "Subnets", "Security groups", "DNS name"], rows) if rows else "None."]
    rows = []
    for r in doc.of_type("aws_lb_listener"):
        v = r.values
        actions = ", ".join(a.get("type", "") for a in v.get("default_action") or [])
        rows.append([lb_by_arn.get(v.get("load_balancer_arn"), arn_name(v.get("load_balancer_arn") or "")), v.get("protocol"), v.get("port"), actions])
    if rows:
        lines += ["", "### Listeners", "", table(["Load balancer", "Protocol", "Port", "Default action"], sorted(rows, key=lambda x: (str(x[0]), str(x[2]))))]
    rows = []
    for r in doc.of_type("aws_lb_target_group"):
        v = r.values
        hc = (v.get("health_check") or [{}])[0] if v.get("health_check") else {}
        rows.append([v.get("name"), v.get("protocol"), v.get("port"), v.get("target_type"), hc.get("path") or hc.get("protocol") or ""])
    if rows:
        lines += ["", "### Target groups", "", table(["Name", "Protocol", "Port", "Target type", "Health check"], rows)]

    rows = []
    for r in doc.of_type("aws_api_gateway_rest_api"):
        v = r.values
        types = ", ".join(t for ec in v.get("endpoint_configuration") or [] for t in ec.get("types") or [])
        rows.append([v.get("name"), code(v.get("id")), "REST", types])
    for r in doc.of_type("aws_apigatewayv2_api"):
        v = r.values
        rows.append([v.get("name"), code(v.get("id")), v.get("protocol_type"), code(v.get("api_endpoint"))])
    lines += ["", "## API Gateway", "", table(["API", "ID", "Kind", "Endpoint"], rows) if rows else "None."]
    rows = []
    for r in doc.of_type("aws_api_gateway_stage", "aws_apigatewayv2_stage"):
        v = r.values
        api_id = v.get("rest_api_id") or v.get("api_id")
        rows.append([api_names.get(api_id, api_id), v.get("stage_name") or v.get("name"), "yes" if v.get("web_acl_arn") else "no"])
    if rows:
        lines += ["", "### Stages", "", table(["API", "Stage", "WAF"], sorted(rows, key=lambda x: (str(x[0]), str(x[1]))))]
    rows = []
    for r in doc.of_type("aws_api_gateway_domain_name", "aws_apigatewayv2_domain_name"):
        rows.append([r.values.get("domain_name")])
    maps = []
    for r in doc.of_type("aws_api_gateway_base_path_mapping", "aws_apigatewayv2_api_mapping"):
        v = r.values
        maps.append([v.get("domain_name"), v.get("base_path") or v.get("api_mapping_key") or "/", api_names.get(v.get("api_id"), v.get("api_id")), v.get("stage_name") or v.get("stage")])
    if maps:
        lines += ["", "### Custom domains", "", table(["Domain", "Base path", "API", "Stage"], sorted(maps, key=lambda x: (str(x[0]), str(x[1]))))]
    elif rows:
        lines += ["", "### Custom domains", "", table(["Domain"], rows)]
    rows = []
    for r in doc.of_type("aws_api_gateway_vpc_link"):
        v = r.values
        rows.append([v.get("name"), code(v.get("id")), ", ".join(sorted(lb_by_arn.get(a, arn_name(a)) for a in v.get("target_arns") or []))])
    if rows:
        lines += ["", "### VPC links", "", table(["Name", "ID", "Targets"], rows)]

    rows = []
    for r in doc.of_type("aws_wafv2_web_acl"):
        v = r.values
        assoc = [arn_name(a.values.get("resource_arn") or "") for a in doc.of_type("aws_wafv2_web_acl_association") if a.values.get("web_acl_arn") == v.get("arn")]
        rows.append([v.get("name"), v.get("scope"), len(v.get("rule") or []), ", ".join(sorted(assoc))])
    if rows:
        lines += ["", "## WAF", "", table(["Web ACL", "Scope", "Rules", "Attached to"], rows)]

    zones = doc.of_type("aws_route53_zone")
    rows = []
    for r in doc.of_type("aws_route53_record"):
        v = r.values
        if v.get("alias"):
            target = "alias " + ", ".join(sorted(a.get("name", "") for a in v["alias"]))
        else:
            target = ", ".join(sorted(v.get("records") or []))
        rows.append([v.get("name"), v.get("type"), target])
    lines += ["", "## DNS", "", "Zones: " + (", ".join(code(z.values.get("name")) for z in zones) or "none") + "."]
    if rows:
        lines += ["", table(["Record", "Type", "Value"], sorted(rows, key=lambda x: (str(x[0]), str(x[1]))))]
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------- inventory


def output_value(value: Any) -> str:
    if isinstance(value, str):
        return value
    return json.dumps(value, sort_keys=True, separators=(", ", ": "))


def render_inventory(doc: TfDoc) -> str:
    by_app: dict[str, list[Resource]] = {}
    for r in doc.resources:
        by_app.setdefault(r.app or "untagged", []).append(r)
    lines = [
        "Every resource Terraform manages in `accounts/aa365` (acc2), grouped by the `App` tag. Resources without tags",
        "(policy attachments, records, sub-resources) are under *untagged*. Configuration sub-resources are counted, not listed.",
        "",
        "## Summary",
        "",
        table(
            ["App", "Resources", "Listed below", "Types"],
            [
                [app, len(rs), sum(1 for r in rs if r.type not in INVENTORY_DETAIL_TYPES), len({r.type for r in rs})]
                for app, rs in sorted(by_app.items())
            ]
            + [["**all**", len(doc.resources), sum(1 for r in doc.resources if r.type not in INVENTORY_DETAIL_TYPES), len({r.type for r in doc.resources})]],
        ),
    ]
    for app, rs in sorted(by_app.items()):
        listed = sorted((r for r in rs if r.type not in INVENTORY_DETAIL_TYPES), key=lambda r: (r.type, r.address))
        counted: dict[str, int] = {}
        for r in rs:
            if r.type in INVENTORY_DETAIL_TYPES:
                counted[r.type] = counted.get(r.type, 0) + 1
        lines += ["", f"## {app}", ""]
        if listed:
            lines.append(table(["Type", "Name", "Terraform address"], [[code(r.type), resource_name(r), code(r.address)] for r in listed]))
        if counted:
            lines += ["", "Counted only: " + ", ".join(f"{code(t)} {n}" for t, n in sorted(counted.items())) + "."]

    rows = []
    for name in sorted(doc.outputs):
        o = doc.outputs[name] or {}
        if o.get("sensitive"):
            rows.append([code(name), "(sensitive, not shown)"])
        elif "value" not in o:
            rows.append([code(name), "(known after apply)"])
        else:
            rows.append([code(name), code(output_value(o.get("value")))])
    lines += ["", "## Terraform outputs", "", "Read live with `terraform -chdir=accounts/aa365 output -json` (AA-CIS-Infra).", ""]
    lines.append(table(["Output", "Value"], rows) if rows else "None.")
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------- IAM


def _as_list(v: Any) -> list:
    if v is None:
        return []
    return v if isinstance(v, list) else [v]


def _short_sub(sub: str) -> str:
    """repo:Org@1/Repo@2:context -> Repo:context."""
    m = re.match(r"^repo:[^/]+/([^:@]+)(?:@\d+)?:(.*)$", sub)
    return f"{m.group(1)}:{m.group(2)}" if m else sub


def trust_text(policy_json: str) -> str:
    try:
        policy = json.loads(policy_json or "{}")
    except ValueError:
        return "(unparsed)"
    parts = []
    for st in _as_list(policy.get("Statement")):
        if st.get("Effect") != "Allow":
            continue
        principal = st.get("Principal") or {}
        if isinstance(principal, str):
            principal = {"AWS": principal}
        who = []
        for svc in _as_list(principal.get("Service")):
            who.append(svc)
        for fed in _as_list(principal.get("Federated")):
            who.append("GitHub OIDC" if "token.actions.githubusercontent.com" in fed else arn_name(fed))
        for aws in _as_list(principal.get("AWS")):
            who.append(aws if not aws.startswith("arn:aws:iam::") else aws.split("::", 1)[1])
        cond_bits = []
        for op, conds in (st.get("Condition") or {}).items():
            for key, val in conds.items():
                if key.endswith(":sub"):
                    cond_bits.append("sub " + ", ".join(_short_sub(s) for s in _as_list(val)))
                elif key.endswith(":ExternalId"):
                    cond_bits.append("ExternalId")
                elif key.endswith(":aud"):
                    continue
                elif key.endswith(":ref"):
                    cond_bits.append("ref " + ", ".join(str(x) for x in _as_list(val)))
                else:
                    cond_bits.append(key.split(":")[-1])
        text = ", ".join(who) or "?"
        if cond_bits:
            text += " (" + "; ".join(cond_bits) + ")"
        parts.append(text)
    return "; ".join(parts)


def policy_actions(policy_json: str) -> list[str]:
    try:
        policy = json.loads(policy_json or "{}")
    except ValueError:
        return ["(unparsed)"]
    actions = set()
    for st in _as_list(policy.get("Statement")):
        effect = st.get("Effect", "Allow")
        for a in _as_list(st.get("Action")) + _as_list(st.get("NotAction")):
            prefix = "NOT " if "NotAction" in st and a in _as_list(st.get("NotAction")) else ""
            actions.add(("Deny " if effect == "Deny" else "") + prefix + a)
    return sorted(actions)


def render_iam(doc: TfDoc) -> str:
    attachments: dict[str, set[str]] = {}
    for r in doc.of_type("aws_iam_role_policy_attachment"):
        attachments.setdefault(r.values.get("role"), set()).add(arn_name(r.values.get("policy_arn") or ""))
    inline: dict[str, dict[str, str]] = {}
    for r in doc.of_type("aws_iam_role_policy"):
        role = r.values.get("role") or ""
        inline.setdefault(role, {})[r.values.get("name") or r.address] = r.values.get("policy") or ""

    roles = sorted(doc.of_type("aws_iam_role"), key=lambda r: r.values.get("name") or "")
    rows, detail = [], []
    for r in roles:
        v = r.values
        name = v.get("name") or r.address
        managed = set(attachments.get(name, set())) | {arn_name(a) for a in v.get("managed_policy_arns") or []}
        pols = dict(inline.get(name, {}))
        for ip in v.get("inline_policy") or []:
            if ip.get("name") and ip.get("policy"):
                pols.setdefault(ip["name"], ip["policy"])
        rows.append(
            [
                code(name),
                r.app,
                arn_name(v.get("permissions_boundary") or "") or "none",
                trust_text(v.get("assume_role_policy") or ""),
                ", ".join(sorted(managed)) or "none",
                ", ".join(sorted(pols)) or "none",
                v.get("description") or "",
            ]
        )
        for pname in sorted(pols):
            detail.append([code(name), code(pname), Raw(", ".join(f"`{cell(a)}`" for a in policy_actions(pols[pname])))])

    lines = [
        "IAM roles Terraform manages in `accounts/aa365` (acc2): who may assume each role, its permissions boundary,",
        "and its policies. The Bedrock and Cost Explorer satellite roles in acc3 live in their own root and are",
        "not listed. Access review: root `docs/security/` (SEC-05).",
        "",
        f"**Totals:** {len(roles)} roles, {sum(len(p) for p in inline.values())} inline policies, "
        f"{len(doc.of_type('aws_iam_policy'))} customer-managed policies.",
        "",
        "## Roles",
        "",
        table(["Role", "App", "Boundary", "Trusted by", "Managed policies", "Inline policies", "Description"], rows),
        "",
        "## Inline policy actions",
        "",
        "Actions per inline policy (`Deny` marks deny statements). Resources and conditions are in the Terraform source.",
        "",
        table(["Role", "Policy", "Actions"], detail) if detail else "None.",
    ]
    rows = [[code(p.values.get("name")), p.values.get("description") or "", Raw(", ".join(f"`{cell(a)}`" for a in policy_actions(p.values.get("policy") or "")))] for p in doc.of_type("aws_iam_policy")]
    lines += ["", "## Customer-managed policies", "", table(["Policy", "Description", "Actions"], rows) if rows else "None."]
    rows = [[code(p.values.get("url")), ", ".join(p.values.get("client_id_list") or [])] for p in doc.of_type("aws_iam_openid_connect_provider")]
    if rows:
        lines += ["", "## OIDC providers", "", table(["URL", "Audiences"], rows)]
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------- pages


@dataclass(frozen=True)
class PageSpec:
    filename: str
    id: str
    title: str
    description: str
    related: tuple[str, ...]


SPECS = {
    "alarms.md": PageSpec(
        "alarms.md",
        "OPS-07",
        "Monitoring and alarm catalog",
        "Every CloudWatch alarm and EventBridge alarm rule of the acc2 stack with its app, condition, notified topic and runbook link; generated from Terraform.",
        ("OPS-04", "OPS-01", "AA-893"),
    ),
    "network.md": PageSpec(
        "network.md",
        "ARCH-02-tables",
        "Network and edge tables",
        "Generated tables of the acc2 VPC, subnets, route tables, security groups, load balancers, API Gateway, WAF and DNS records.",
        ("ARCH-02", "ARCH-03", "AA-893"),
    ),
    "inventory.md": PageSpec(
        "inventory.md",
        "ARCH-03",
        "Resource inventory",
        "Generated list of every Terraform-managed resource in acc2 grouped by App tag, plus the root Terraform outputs.",
        ("ARCH-02", "ARCH-04", "AA-893"),
    ),
    "iam-roles.md": PageSpec(
        "iam-roles.md",
        "ARCH-04-tables",
        "IAM role tables",
        "Generated table of the acc2 IAM roles: trust, permissions boundary, managed and inline policies with their actions.",
        ("ARCH-04", "SEC-05", "AA-893"),
    ),
}


def fingerprint(body: str) -> str:
    return hashlib.sha256(body.encode("utf-8")).hexdigest()


def page(spec: PageSpec, body: str, *, date: str, sha: str, source: str, blurb: Optional[tuple[str, ...]] = None,
         aliases: Optional[Mapping[str, str]] = None) -> str:
    """The published page: front matter, marker, blurb, masked body (AA-981).

    The fingerprint covers the masked body, so `changed` compares what is published. `aliases` defaults
    to env AWS_ACCOUNT_ALIASES (aws_mask.load_aliases)."""
    if aliases is None:
        aliases = aws_mask.load_aliases()
    body = aws_mask.mask_text(body, aliases)
    fm = [
        "---",
        f"id: {spec.id}",
        f"title: {json.dumps(spec.title)}",
        f"description: {json.dumps(spec.description)}",
        "type: reference",
        "status: active",
        "owner: nghiep",
        "audience: [engineer, devops, agent]",
        "applies_to: [ecosystem]",
        f"last_reviewed: {date}",
        "review_every_days: 45",
        "generated: true",
        f"generator: {GENERATOR}",
        "related: [" + ", ".join(spec.related) + "]",
        "---",
    ]
    if blurb is None:
        blurb = (
            f"> **Generated - do not edit.** Source: {source}. AA-CIS-Infra `tools/docs/gen_docs.py` renders it from the",
            "> Terraform state nightly and after each apply, and opens a PR here only when the content changes. To change a row,",
            "> change the Terraform in AA-CIS-Infra.",
        )
    head = [
        "",
        f"# {spec.title}",
        "",
        f"<!-- GENERATED by AA-CIS-Infra .github/workflows/docs-gen.yml from AA-CIS-Infra@{sha} - do not edit -->",
        f"<!-- docs-fingerprint: {fingerprint(body)} -->",
        "",
        *blurb,
        "",
    ]
    text = aws_mask.mask_text("\n".join(fm + head), aliases) + "\n" + body
    aws_mask.assert_clean(text, spec.filename)
    return text


def render_all(doc: TfDoc, root_dir: Optional[Path]) -> tuple[dict[str, str], Problems]:
    problems = Problems()
    bodies = {
        "alarms.md": render_alarms(doc, root_dir, problems),
        "network.md": render_network(doc),
        "inventory.md": render_inventory(doc),
        "iam-roles.md": render_iam(doc),
    }
    return bodies, problems


# --------------------------------------------------------------------------- changed


def read_meta(path: Path) -> tuple[Optional[str], Optional[str]]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return None, None
    fp = FINGERPRINT_RE.search(text)
    lr = LAST_REVIEWED_RE.search(text)
    return (fp.group(1) if fp else None, lr.group(1) if lr else None)


def changed_pages(new_dir: Path, old_dir: Path, max_age_days: int, today: dt.date,
                  names: Iterable[str] = PAGES) -> list[str]:
    out = []
    for name in names:
        new_fp, _ = read_meta(new_dir / name)
        if new_fp is None:
            continue
        old_fp, old_date = read_meta(old_dir / name)
        stale = True
        if old_date:
            try:
                stale = (today - dt.date.fromisoformat(old_date)).days > max_age_days
            except ValueError:
                stale = True
        if old_fp != new_fp or stale:
            out.append(name)
    return out


# --------------------------------------------------------------------------- check-source

BLOCK_RE = re.compile(r'^resource\s+"(aws_cloudwatch_metric_alarm|aws_cloudwatch_event_rule|aws_cloudwatch_event_target)"\s+"([^"]+)"\s*\{', re.M)


def _block(text: str, start: int) -> str:
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start : i + 1]
    return text[start:]


def _attr_line(block: str, attr: str) -> str:
    m = re.search(rf"^\s*{attr}\s*=\s*(.*)$", block, re.M)
    return m.group(1) if m else ""


def check_source(dirs: Iterable[Path]) -> list[str]:
    """Offline guard: every alarm and every SNS-notifying EventBridge rule has a runbook suffix."""
    problems = []
    rules: dict[str, tuple[str, str]] = {}
    targets: list[tuple[str, str, str]] = []
    for d in dirs:
        for tf in sorted(Path(d).rglob("*.tf")):
            if ".terraform" in tf.parts:
                continue
            text = tf.read_text(encoding="utf-8")
            for m in BLOCK_RE.finditer(text):
                rtype, rname = m.group(1), m.group(2)
                block = _block(text, m.end() - 1)
                where = f"{tf}:{text.count(chr(10), 0, m.start()) + 1}"
                if rtype == "aws_cloudwatch_metric_alarm":
                    desc = _attr_line(block, "alarm_description")
                    if "runbook_suffix." not in desc and "Runbook: " not in desc:
                        problems.append(f"{where}: aws_cloudwatch_metric_alarm.{rname} has no runbook suffix in alarm_description")
                elif rtype == "aws_cloudwatch_event_rule":
                    rules[rname] = (where, _attr_line(block, "description"))
                else:
                    arn = _attr_line(block, "arn")
                    rule = _attr_line(block, "rule")
                    tmpl = _attr_line(block, "input_template")
                    if "aws_sns_topic." in arn or "topic_arn" in arn:
                        rm = re.search(r"aws_cloudwatch_event_rule\.([A-Za-z0-9_-]+)\.", rule)
                        targets.append((where, rm.group(1) if rm else rule, tmpl))
    for where, rule, tmpl in targets:
        if rule not in rules:
            continue  # rule defined elsewhere (module input); nothing to check here
        rwhere, desc = rules[rule]
        if "runbook_suffix." not in desc and "Runbook: " not in desc:
            problems.append(f"{rwhere}: aws_cloudwatch_event_rule.{rule} notifies SNS but its description has no runbook suffix")
        if tmpl and "runbook_suffix." not in tmpl and "Runbook: " not in tmpl:
            problems.append(f"{where}: the SNS target of rule {rule} has no runbook suffix in input_template (the e-mail text)")
    return problems


# --------------------------------------------------------------------------- CLI


def main(argv: Optional[list[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    r = sub.add_parser("render", help="render the four pages")
    r.add_argument("--tf-json", required=True, type=Path)
    r.add_argument("--out-dir", required=True, type=Path)
    r.add_argument("--root-dir", type=Path, help="root repo checkout: runbook files must exist there")
    r.add_argument("--source", default="local run")
    r.add_argument("--sha", default="local")
    r.add_argument("--date", default=dt.datetime.now(dt.timezone.utc).date().isoformat())
    r.add_argument("--problems-file", type=Path)
    r.add_argument("--strict", action="store_true", help="exit 1 when a runbook link is missing or broken")

    c = sub.add_parser("changed", help="list pages to publish")
    c.add_argument("--new", required=True, type=Path)
    c.add_argument("--old", required=True, type=Path)
    c.add_argument("--max-age-days", type=int, default=30)
    c.add_argument("--date", default=dt.datetime.now(dt.timezone.utc).date().isoformat())

    s = sub.add_parser("check-source", help="offline runbook-suffix guard on .tf files")
    s.add_argument("dirs", nargs="+", type=Path)

    args = ap.parse_args(argv)

    if args.cmd == "render":
        try:
            doc = load_tf_json(args.tf_json)
            aliases = aws_mask.load_aliases()
        except (InputError, aws_mask.AliasError) as exc:
            print(f"::error::{exc}", file=sys.stderr)
            return 2
        bodies, problems = render_all(doc, args.root_dir)
        args.out_dir.mkdir(parents=True, exist_ok=True)
        for name, body in bodies.items():
            (args.out_dir / name).write_text(
                page(SPECS[name], body, date=args.date, sha=args.sha, source=args.source, aliases=aliases), encoding="utf-8"
            )
        print(f"rendered {len(bodies)} pages from the {doc.kind} JSON ({len(doc.resources)} resources) into {args.out_dir}")
        for p in problems.items:
            print(f"::error title=alarm runbook::{p}")
        if args.problems_file:
            args.problems_file.write_text("".join(f"{p}\n" for p in problems.items), encoding="utf-8")
        return 1 if (problems.items and args.strict) else 0

    if args.cmd == "changed":
        for name in changed_pages(args.new, args.old, args.max_age_days, dt.date.fromisoformat(args.date),
                                  PAGES + EXTRA_PAGES):
            print(name)
        return 0

    problems = check_source(args.dirs)
    for p in problems:
        print(f"::error title=alarm runbook::{p}")
    if not problems:
        print("every alarm and SNS-notifying EventBridge rule carries a runbook suffix")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
