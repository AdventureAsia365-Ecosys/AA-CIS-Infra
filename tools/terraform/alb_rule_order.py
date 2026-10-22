#!/usr/bin/env python3
"""ALB HTTP listener rule-order check (AA-931, CRM-03, v2.2 V3).

The shared ALB's :80 listener is reached by API Gateway (VPC link -> NLB) and by CloudFront (VPC
origin -> NLB). CloudFront adds a secret origin header (X-AA-Origin) to every request. Rules are
evaluated by priority and the first match wins, so the order is the security control
(accounts/aa365/alb_rules.tf):

  R1  priorities are unique;
  R2  at most one deny rule: only an origin-header condition with value "*", action fixed-response 403;
  R3  every rule with an exact origin-header condition forwards, also has a host-header condition and
      sits BELOW (lower number than) the deny rule;
  R4  every rule without an origin-header condition sits ABOVE the deny rule (CloudFront traffic that
      matched no host rule must hit the 403 before any CIS / Booking rule or the default action);
  R5  an exact origin-header rule without a deny rule is an error (CloudFront traffic for other hosts
      would fall through to CIS);
  S1  (source mode) every aws_lb_listener_rule on module.alb.http_listener_arn takes its priority from
      local.alb_http_rule_priorities.<key>, the key exists, and the map values are unique.

Two inputs:
  --source accounts/aa365   the Terraform source (CI, alb-rule-order.yml)
  --live rules.json         output of `aws elbv2 describe-rules --listener-arn <:80 listener> --output json`
                            after an apply (the file holds the secret header value: keep it in
                            .tmp-session and delete it after; this script never prints values)

Exit 0 = all checks pass, 1 = violations (listed), 2 = bad input. Stdlib only.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

DEFAULT_ORIGIN_HEADER = "x-aa-origin"
PRIORITY_MAP_LOCAL = "alb_http_rule_priorities"
HEADER_NAME_LOCAL = "alb_origin_header_name"
HTTP_LISTENER_REF = "module.alb.http_listener_arn"


class InputError(Exception):
    """The input cannot be read or parsed."""


@dataclass
class Rule:
    name: str
    priority: Optional[int]  # None = the listener's default action (lowest precedence)
    action: str
    status_code: Optional[str] = None
    has_host: bool = False
    has_other_conditions: bool = False  # path, query, source-ip, method, other headers
    origin_values: Optional[list[str]] = None  # None = no origin-header condition

    @property
    def origin_kind(self) -> str:
        if self.origin_values is None:
            return "none"
        if self.origin_values == ["*"]:
            return "wildcard"
        if "*" in self.origin_values or any("*" in v or "?" in v for v in self.origin_values):
            return "pattern"
        return "exact"

    @property
    def sort_key(self) -> float:
        return float("inf") if self.priority is None else float(self.priority)


@dataclass
class Report:
    rules: list[Rule]
    errors: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not self.errors


def check_rules(rules: list[Rule]) -> list[str]:
    """R1-R5 on normalised rules. Messages name rules and priorities only, never header values."""
    errors: list[str] = []

    seen: dict[int, str] = {}
    for r in rules:
        if r.priority is None:
            continue
        if r.priority in seen:
            errors.append(f"R1 duplicate priority {r.priority}: {seen[r.priority]} and {r.name}")
        seen[r.priority] = r.name

    denies = [r for r in rules if r.origin_kind == "wildcard"]
    for r in denies:
        if r.action != "fixed-response" or r.status_code != "403":
            errors.append(f"R2 {r.name}: an any-value origin-header rule must answer fixed-response 403")
        if r.has_host or r.has_other_conditions:
            errors.append(f"R2 {r.name}: the deny rule must have the origin-header condition only")
    if len(denies) > 1:
        errors.append("R2 more than one any-value origin-header rule: " + ", ".join(r.name for r in denies))

    for r in rules:
        if r.origin_kind == "pattern":
            errors.append(f"R3 {r.name}: origin-header values must be one exact secret or the single '*'")

    exact = [r for r in rules if r.origin_kind == "exact"]
    deny = denies[0] if denies else None
    if exact and deny is None:
        errors.append(
            "R5 origin-header host rules exist but there is no deny rule: CloudFront traffic for any other "
            "host would reach the next rule or the default action (CIS)"
        )

    for r in exact:
        if r.action != "forward":
            errors.append(f"R3 {r.name}: an exact origin-header rule must forward")
        if not r.has_host:
            errors.append(f"R3 {r.name}: an exact origin-header rule must also match a host header")
        if deny is not None and not r.sort_key < deny.sort_key:
            errors.append(f"R3 {r.name} (priority {r.priority}) must sit below the deny rule ({deny.priority})")

    if deny is not None:
        for r in rules:
            if r.origin_kind == "none" and not r.sort_key > deny.sort_key:
                errors.append(
                    f"R4 {r.name} (priority {r.priority}) has no origin-header condition and must sit above "
                    f"the deny rule ({deny.priority})"
                )
    return errors


# ----------------------------------------------------------------------------------------------
# Live mode: aws elbv2 describe-rules JSON
# ----------------------------------------------------------------------------------------------
def rules_from_describe(data: dict, origin_header: str = DEFAULT_ORIGIN_HEADER) -> list[Rule]:
    if not isinstance(data, dict) or not isinstance(data.get("Rules"), list):
        raise InputError("not an `aws elbv2 describe-rules` JSON (no Rules list)")
    out: list[Rule] = []
    for raw in data["Rules"]:
        prio_raw = str(raw.get("Priority", ""))
        if raw.get("IsDefault") or prio_raw == "default":
            priority = None
        else:
            try:
                priority = int(prio_raw)
            except ValueError as exc:
                raise InputError(f"rule priority {prio_raw!r} is not a number") from exc
        actions = sorted(raw.get("Actions") or [], key=lambda a: a.get("Order", 0))
        action = actions[-1] if actions else {}
        rule = Rule(
            name=str(raw.get("RuleArn", "?")).rsplit("/", 1)[-1] if priority is not None else "default",
            priority=priority,
            action=str(action.get("Type", "")),
            status_code=(action.get("FixedResponseConfig") or {}).get("StatusCode"),
        )
        for cond in raw.get("Conditions") or []:
            fld = cond.get("Field")
            if fld == "host-header":
                rule.has_host = True
            elif fld == "http-header":
                cfg = cond.get("HttpHeaderConfig") or {}
                if str(cfg.get("HttpHeaderName", "")).lower() == origin_header:
                    rule.origin_values = list(cfg.get("Values") or [])
                else:
                    rule.has_other_conditions = True
            else:
                rule.has_other_conditions = True
        out.append(rule)
    return out


# ----------------------------------------------------------------------------------------------
# Source mode: the Terraform files of one root
# ----------------------------------------------------------------------------------------------
def _strip_comments(text: str) -> str:
    """Blank out comments, keep strings (and offsets/lines) intact."""
    out: list[str] = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            out.append(text[i : j + 1])
            i = j + 1
        elif c == "#" or text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j == -1 else j
            out.append(" " * (j - i))
            i = j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j == -1 else j + 2
            out.append(re.sub(r"[^\n]", " ", text[i:j]))
            i = j
        else:
            out.append(c)
            i += 1
    return "".join(out)


def _block_end(text: str, open_idx: int) -> int:
    """Index of the brace closing the one at open_idx, skipping string literals."""
    depth, i, n = 0, open_idx, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            i += 1
            while i < n and text[i] != '"':
                i += 2 if text[i] == "\\" else 1
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise InputError("unbalanced braces")


def _blocks(text: str, head_re: str) -> list[tuple[re.Match, str]]:
    found = []
    for m in re.finditer(head_re, text):
        start = text.index("{", m.end() - 1)
        found.append((m, text[start + 1 : _block_end(text, start)]))
    return found


def _locals(text: str) -> tuple[dict[str, int], Optional[str]]:
    priorities: dict[str, int] = {}
    header: Optional[str] = None
    for _, body in _blocks(text, r"(?m)^\s*locals\s*\{"):
        for m, map_body in _blocks(body, rf"{PRIORITY_MAP_LOCAL}\s*=\s*\{{"):
            for key, val in re.findall(r"(?m)^\s*([A-Za-z_][\w-]*)\s*=\s*(\S+)", map_body):
                if not val.isdigit():
                    raise InputError(f"{PRIORITY_MAP_LOCAL}.{key} is not a literal integer")
                if key in priorities:
                    raise InputError(f"{PRIORITY_MAP_LOCAL}.{key} defined twice")
                priorities[key] = int(val)
        hm = re.search(rf'(?m)^\s*{HEADER_NAME_LOCAL}\s*=\s*"([^"]+)"', body)
        if hm:
            header = hm.group(1)
    return priorities, header


def rules_from_source(root: Path) -> tuple[list[Rule], list[str], str]:
    files = sorted(root.glob("*.tf"))
    if not files:
        raise InputError(f"no *.tf files in {root}")
    texts = {f.name: _strip_comments(f.read_text(encoding="utf-8")) for f in files}

    priorities: dict[str, int] = {}
    header: Optional[str] = None
    for text in texts.values():
        p, h = _locals(text)
        for k, v in p.items():
            if k in priorities:
                raise InputError(f"{PRIORITY_MAP_LOCAL}.{k} defined in two files")
            priorities[k] = v
        header = header or h
    origin_header = (header or DEFAULT_ORIGIN_HEADER).lower()

    errors: list[str] = []
    if not priorities:
        errors.append(f"S1 local.{PRIORITY_MAP_LOCAL} not found")
    dup_values = sorted({v for v in priorities.values() if list(priorities.values()).count(v) > 1})
    for v in dup_values:
        errors.append(f"S1 priority {v} used by more than one key of local.{PRIORITY_MAP_LOCAL}")

    rules: list[Rule] = []
    used_keys: set[str] = set()
    for fname, text in texts.items():
        for m, body in _blocks(text, r'resource\s+"aws_lb_listener_rule"\s+"([\w-]+)"\s*\{'):
            name = f"{fname}:{m.group(1)}"
            if HTTP_LISTENER_REF not in body:
                continue  # another listener: not this check's business
            pm = re.search(r"(?m)^\s*priority\s*=\s*(.+?)\s*$", body)
            priority: Optional[int] = None
            if not pm:
                errors.append(f"S1 {name}: no priority (an unset priority is assigned by AWS, order unknown)")
            else:
                ref = re.fullmatch(rf"local\.{PRIORITY_MAP_LOCAL}\.([\w-]+)", pm.group(1))
                if not ref:
                    errors.append(f"S1 {name}: priority must be local.{PRIORITY_MAP_LOCAL}.<key>, got {pm.group(1)!r}")
                elif ref.group(1) not in priorities:
                    errors.append(f"S1 {name}: unknown key {ref.group(1)!r} in local.{PRIORITY_MAP_LOCAL}")
                else:
                    used_keys.add(ref.group(1))
                    priority = priorities[ref.group(1)]

            actions = _blocks(body, r"(?m)^\s*action\s*\{")
            action_type, status = "", None
            if actions:
                am = re.search(r'(?m)^\s*type\s*=\s*"([\w-]+)"', actions[-1][1])
                action_type = am.group(1) if am else ""
                sm = re.search(r'status_code\s*=\s*"(\d+)"', actions[-1][1])
                status = sm.group(1) if sm else None
            rule = Rule(name=name, priority=priority, action=action_type, status_code=status)

            for _, cond in _blocks(body, r"(?m)^\s*condition\s*\{"):
                if re.search(r"(?m)^\s*host_header\s*\{", cond):
                    rule.has_host = True
                hh = _blocks(cond, r"(?m)^\s*http_header\s*\{")
                for _, hbody in hh:
                    nm = re.search(r"(?m)^\s*http_header_name\s*=\s*(.+?)\s*$", hbody)
                    hname = (nm.group(1) if nm else "").strip()
                    is_origin = hname == f"local.{HEADER_NAME_LOCAL}" or hname.strip('"').lower() == origin_header
                    if not is_origin:
                        rule.has_other_conditions = True
                        continue
                    vm = re.search(r"(?ms)^\s*values\s*=\s*\[(.*?)\]", hbody)
                    items = [v.strip() for v in (vm.group(1) if vm else "").split(",") if v.strip()]
                    # A literal "*" is the wildcard; anything else (a reference) is the exact secret.
                    rule.origin_values = ["*" if v == '"*"' else "<secret>" for v in items]
                if re.search(r"(?m)^\s*(path_pattern|query_string|source_ip|http_request_method)\s*\{", cond):
                    rule.has_other_conditions = True
            rules.append(rule)

    for key in sorted(set(priorities) - used_keys):
        errors.append(f"S1 local.{PRIORITY_MAP_LOCAL}.{key} is not used by any rule (stale entry)")
    return rules, errors, origin_header


def run(source: Optional[Path], live: Optional[Path]) -> Report:
    if source is not None:
        rules, errors, _ = rules_from_source(source)
        return Report(rules=rules, errors=errors + check_rules(rules))
    assert live is not None
    try:
        data = json.loads(live.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise InputError(f"cannot read {live}: {exc}") from exc
    rules = rules_from_describe(data)
    return Report(rules=rules, errors=check_rules(rules))


def main(argv: Optional[list[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--source", type=Path, help="Terraform root directory (e.g. accounts/aa365)")
    g.add_argument("--live", type=Path, help="JSON from `aws elbv2 describe-rules`")
    args = ap.parse_args(argv)
    try:
        report = run(args.source, args.live)
    except InputError as exc:
        print(f"alb_rule_order: bad input: {exc}", file=sys.stderr)
        return 2
    for r in sorted(report.rules, key=lambda r: r.sort_key):
        prio = "default" if r.priority is None else str(r.priority)
        print(f"  {prio:>7}  {r.name}  action={r.action}  origin_header={r.origin_kind}  host={r.has_host}")
    if report.ok:
        print(f"alb_rule_order: OK ({len(report.rules)} rules)")
        return 0
    for e in report.errors:
        print(f"alb_rule_order: {e}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
