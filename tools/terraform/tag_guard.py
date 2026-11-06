#!/usr/bin/env python3
"""Terraform tag guard: every taggable AWS resource a plan creates or updates carries the mandatory tags (S271).

Reads the JSON of a saved plan (`terraform show -json tfplan`) and the tagging standard's machine copy
(tools/terraform/tag_policy.json; the source is root docs/architecture/tagging-standard.md, FIN-03). For each AWS
resource the plan creates, updates or replaces it checks the tags the resource will end up with (`tags_all`: the
provider default_tags merged with the resource's own tags):

  missing      a mandatory key (Environment, Project, App, Component, Owner, ManagedBy, CostCenter,
               DataClassification) is absent or empty
  value        a mandatory key holds a value outside the allowed list; ManagedBy must be `terraform` here
  forbidden    a key duplicates a mandatory key under another spelling (Env, environment, app, Service, Account ...)
  pattern      an optional key breaks its pattern (Issue must look like AA-123)
  too-many     more tags than AWS accepts on that type (S3 objects: 10)

Taggable means the planned resource has a `tags_all` or `tags` attribute; types without one are skipped. Types that
expose tags but cannot carry the keys are listed with a reason under `exempt_types` in the policy file. A value that is
unknown until apply counts as present (only its value is not checked); a whole tag map unknown until apply is listed
as a warning (an error with --strict).

Deleted, read and no-op resources are not checked (--all also checks no-op ones: a full inventory of the root).

Output: addresses (identity-store keys redacted, as plan_guard.py does), types, keys and the offending tag values only, never other attribute values (the plan JSON holds
secrets in clear text). Exit codes: 0 compliant, 1 violations, 2 bad input (fail closed).

Stdlib only. Usage:
  terraform show -json tfplan > plan.json
  python3 tools/terraform/tag_guard.py plan.json [--policy tools/terraform/tag_policy.json] [--all] [--strict]
                                                 [--summary $GITHUB_STEP_SUMMARY]
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import Counter
from dataclasses import dataclass
from typing import Any, Iterable, Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from plan_guard import redact_address  # noqa: E402  (identity-store keys out of a public summary, AA-1004)

DEFAULT_POLICY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "tag_policy.json")
AWS_PROVIDER = "registry.terraform.io/hashicorp/aws"
_CHECKED_ACTIONS = frozenset({"create", "update"})
MAX_LISTED = 200  # report lines; the counts below the list stay exact


class InputError(Exception):
    """The plan or the policy cannot be read."""


@dataclass(frozen=True)
class Policy:
    mandatory: dict[str, frozenset[str]]
    plan_values: dict[str, str]
    optional_patterns: dict[str, re.Pattern]
    forbidden: frozenset[str]  # lower case
    exempt_types: dict[str, str]
    max_tags: dict[str, int]
    default_max: int


@dataclass(frozen=True)
class Violation:
    address: str
    type: str
    kind: str  # missing | value | forbidden | pattern | too-many | unknown
    detail: str


def load_policy(path: str = DEFAULT_POLICY) -> Policy:
    try:
        with open(path, encoding="utf-8") as fh:
            raw = json.load(fh)
    except FileNotFoundError as exc:
        raise InputError(f"tag policy not found: {path}") from exc
    except json.JSONDecodeError as exc:
        raise InputError(f"tag policy is not valid JSON ({exc.msg} at line {exc.lineno})") from exc
    try:
        mandatory = {k: frozenset(v["values"]) for k, v in raw["mandatory"].items()}
        plan_values = {k: v["plan_value"] for k, v in raw["mandatory"].items() if "plan_value" in v}
        optional = {k: re.compile(v["pattern"]) for k, v in raw.get("optional", {}).items() if "pattern" in v}
        forbidden = frozenset(k.lower() for k in raw.get("forbidden_keys", {}).get("keys", []))
        exempt = {k: str(v) for k, v in raw.get("exempt_types", {}).items() if not k.startswith("_")}
        limits = {k: int(v) for k, v in raw.get("max_tags", {}).items() if not k.startswith("_")}
        default_max = int(raw.get("max_tags", {}).get("_default", 50))
    except (KeyError, TypeError, ValueError, re.error) as exc:
        raise InputError(f"tag policy has an unexpected shape: {exc}") from exc
    if not mandatory or any(not v for v in mandatory.values()):
        raise InputError("tag policy: every mandatory key needs at least one allowed value")
    for key, value in plan_values.items():
        if value not in mandatory[key]:
            raise InputError(f"tag policy: plan_value {value!r} of {key} is not one of its allowed values")
    return Policy(mandatory, plan_values, optional, forbidden, exempt, limits, default_max)


def _tags_after(change: dict) -> tuple[Optional[dict], set[str], bool]:
    """(known tags, keys whose value is unknown, whole map unknown) for the planned state of one resource."""
    after = change.get("after") if isinstance(change.get("after"), dict) else {}
    unknown = change.get("after_unknown") if isinstance(change.get("after_unknown"), dict) else {}
    for attr in ("tags_all", "tags"):
        if attr not in after and attr not in unknown:
            continue
        flag = unknown.get(attr)
        if flag is True:
            return None, set(), True
        tags = after.get(attr) or {}
        if not isinstance(tags, dict):
            raise InputError(f"{attr} is not a map")
        unknown_keys = {k for k, v in flag.items() if v is True} if isinstance(flag, dict) else set()
        return {str(k): v for k, v in tags.items()}, unknown_keys, False
    return None, set(), False


def _is_taggable(change: dict) -> bool:
    after = change.get("after") if isinstance(change.get("after"), dict) else {}
    unknown = change.get("after_unknown") if isinstance(change.get("after_unknown"), dict) else {}
    return any(a in after or a in unknown for a in ("tags_all", "tags"))


def check_tags(address: str, rtype: str, tags: dict, unknown_keys: set[str], policy: Policy) -> list[Violation]:
    """Every rule of the standard for one resource's final tag map."""
    out: list[Violation] = []
    present = set(tags) | unknown_keys
    mandatory_lower = {k.lower(): k for k in policy.mandatory}
    for key, allowed in policy.mandatory.items():
        if key not in present or (key not in unknown_keys and tags.get(key) in (None, "")):
            out.append(Violation(address, rtype, "missing", key))
            continue
        if key in unknown_keys:
            continue
        value = str(tags[key])
        want = policy.plan_values.get(key)
        if want is not None and value != want:
            out.append(Violation(address, rtype, "value", f"{key}={value!r} (a Terraform resource says {want!r})"))
        elif value not in allowed:
            out.append(Violation(address, rtype, "value", f"{key}={value!r} not in {sorted(allowed)}"))
    for key in sorted(present):
        low = key.lower()
        if key in policy.mandatory:
            continue
        if low in mandatory_lower:
            out.append(Violation(address, rtype, "forbidden", f"{key} (spell it {mandatory_lower[low]})"))
        elif low in policy.forbidden:
            out.append(Violation(address, rtype, "forbidden", f"{key} (retired or duplicate key)"))
        elif key in policy.optional_patterns and key not in unknown_keys:
            value = str(tags.get(key))
            if not policy.optional_patterns[key].fullmatch(value):
                out.append(Violation(address, rtype, "pattern", f"{key}={value!r}"))
    limit = policy.max_tags.get(rtype, policy.default_max)
    if len(present) > limit:
        out.append(Violation(address, rtype, "too-many", f"{len(present)} tags, {rtype} accepts {limit}"))
    return out


def find_violations(plan: dict, policy: Policy, include_noop: bool = False) -> tuple[list[Violation], Counter]:
    """All violations of the plan, and counters: checked, exempt, skipped (not taggable)."""
    if not isinstance(plan, dict) or "format_version" not in plan:
        raise InputError("not a Terraform plan JSON (no format_version); use `terraform show -json <planfile>`")
    if "planned_values" not in plan and "resource_changes" not in plan:
        raise InputError("JSON has no planned_values/resource_changes: is this a state, not a plan?")
    changes = plan.get("resource_changes")
    if changes is None:  # a plan with no changes may omit the key
        changes = []
    if not isinstance(changes, list):
        raise InputError("resource_changes is not a list")
    found: list[Violation] = []
    counts: Counter = Counter()
    for rc in changes:
        if not isinstance(rc, dict):
            raise InputError("resource_changes entry is not an object")
        if rc.get("mode", "managed") != "managed" or rc.get("provider_name", AWS_PROVIDER) != AWS_PROVIDER:
            continue
        change = rc.get("change")
        address, rtype = str(rc.get("address", "?")), str(rc.get("type", "?"))
        if not isinstance(change, dict) or not isinstance(change.get("actions"), list):
            raise InputError(f"{address}: change.actions missing")
        actions = set(change["actions"])
        if not (actions & _CHECKED_ACTIONS or (include_noop and actions == {"no-op"})):
            continue
        if not _is_taggable(change):
            counts["not_taggable"] += 1
            continue
        if rtype in policy.exempt_types:
            counts["exempt"] += 1
            continue
        tags, unknown_keys, whole_unknown = _tags_after(change)
        counts["checked"] += 1
        if whole_unknown:
            found.append(Violation(address, rtype, "unknown", "tag map known only after apply"))
            continue
        found.extend(check_tags(address, rtype, tags or {}, unknown_keys, policy))
    return found, counts


def render(violations: list[Violation], counts: Counter, strict: bool) -> tuple[str, int]:
    errors = [v for v in violations if strict or v.kind != "unknown"]
    warnings = [v for v in violations if not strict and v.kind == "unknown"]
    head = (f"Tag guard: {counts['checked']} taggable resource(s) checked, {counts['exempt']} exempt, "
            f"{counts['not_taggable']} without tags.")
    lines = [head]
    if errors:
        by_kind = Counter(v.kind for v in errors)
        lines.append(f"FAILED: {len(errors)} problem(s) on {len({v.address for v in errors})} resource(s) "
                     f"({', '.join(f'{k} {n}' for k, n in sorted(by_kind.items()))}). "
                     "Fix the tags (root docs/architecture/tagging-standard.md) or, for a type AWS cannot tag, add it "
                     "to exempt_types in tools/terraform/tag_policy.json with the reason.")
        for v in errors[:MAX_LISTED]:
            lines.append(f"- `{redact_address(v.address)}` ({v.type}): {v.kind} {v.detail}")
        if len(errors) > MAX_LISTED:
            lines.append(f"- ... and {len(errors) - MAX_LISTED} more")
    else:
        lines.append("OK: every checked resource carries the mandatory tags with allowed values.")
    for v in warnings[:MAX_LISTED]:
        lines.append(f"- warning `{redact_address(v.address)}` ({v.type}): {v.detail}")
    return "\n".join(lines), (1 if errors else 0)


def _load_json(path: str) -> Any:
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except FileNotFoundError as exc:
        raise InputError(f"plan JSON not found: {path}") from exc
    except json.JSONDecodeError as exc:
        raise InputError(f"plan JSON is not valid JSON ({exc.msg} at line {exc.lineno})") from exc


def main(argv: Optional[Iterable[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("plan_json", help="output of `terraform show -json <planfile>`")
    ap.add_argument("--policy", default=DEFAULT_POLICY, help="tag policy JSON (default: tag_policy.json next to this file)")
    ap.add_argument("--all", action="store_true", help="also check resources the plan leaves unchanged (no-op)")
    ap.add_argument("--strict", action="store_true", help="a tag map unknown until apply is an error, not a warning")
    ap.add_argument("--summary", help="append the report to this file (e.g. $GITHUB_STEP_SUMMARY)")
    args = ap.parse_args(list(argv) if argv is not None else None)
    try:
        policy = load_policy(args.policy)
        violations, counts = find_violations(_load_json(args.plan_json), policy, include_noop=args.all)
    except InputError as exc:
        text, code = f"Tag guard: ERROR, {exc} (fail closed).", 2
    else:
        text, code = render(violations, counts, args.strict)
    print(text, file=sys.stderr if code else sys.stdout)
    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as fh:
            fh.write("### Terraform tag guard\n\n" + text + "\n\n")
    return code


if __name__ == "__main__":
    sys.exit(main())
