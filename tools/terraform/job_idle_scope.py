#!/usr/bin/env python3
"""Job-idle scope of a Terraform plan (AA-1023, data standards DM-11.4 for Infra applies).

Reads the JSON of a saved plan (`terraform show -json tfplan`) and says whether the apply would restart or replace
something a running job lives in: an ECS task (CIS api/worker, Booking api, CRM api/web) or the shared RDS
instance. When it does, terraform-apply.yml runs the job-idle gate (.github/scripts/job-idle-gate.sh: the migrator
task in MIGRATION_MODE=idle-gate, the same check as DB Migrate apply) before `terraform apply`, and refuses while
shared.job / booking.job / crm.job / tripplanner.job hold a queued or running non-exempt row or a rerun wave is open.

Gated (any action other than no-op or read):

  aws_ecs_service                       a service update can start a new deployment (network, load balancer,
                                        capacity provider, deployment settings); delete/replace stops its tasks
  aws_ecs_cluster                       replace/delete stops every task of the cluster
  aws_ecs_cluster_capacity_providers    capacity changes can drain the tasks
  aws_db_instance                       a modification can reboot or fail over the shared RDS
  aws_db_parameter_group                a parameter change can need or trigger a reboot

Listed, not gated: aws_ecs_task_definition. Every service has `ignore_changes = [task_definition]`, so a new
revision restarts nothing now; the next app Deploy Dev copies the newest revision (lesson S250: compare its env names
with the running revision after the apply).

Only addresses, types and actions are printed, never attribute values (the plan JSON holds secrets in clear text).
A plan that cannot be read counts as gated (fail closed).

Exit codes: 0 always when the report was written (the decision is the `gated` output), 2 bad arguments.

Stdlib only. Usage:
  python3 tools/terraform/job_idle_scope.py plan.json [--github-output $GITHUB_OUTPUT] [--summary $GITHUB_STEP_SUMMARY]
"""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from typing import Optional

GATED_TYPES = (
    "aws_ecs_service",
    "aws_ecs_cluster",
    "aws_ecs_cluster_capacity_providers",
    "aws_db_instance",
    "aws_db_parameter_group",
)
INFO_TYPES = ("aws_ecs_task_definition",)
QUIET_ACTIONS = (["no-op"], ["read"], [])


@dataclass(frozen=True)
class Change:
    address: str
    type: str
    actions: str


@dataclass
class Scope:
    gated: list
    info: list
    error: str = ""

    @property
    def needs_gate(self) -> bool:
        return bool(self.gated or self.error)


def _label(actions: list) -> str:
    if actions in (["delete", "create"], ["create", "delete"]):
        return "replace"
    return "+".join(actions)


def find_scope(plan: dict) -> Scope:
    if not isinstance(plan, dict) or not isinstance(plan.get("resource_changes", []), list):
        return Scope([], [], error="not a Terraform plan JSON (no resource_changes list)")
    gated, info = [], []
    for rc in plan.get("resource_changes") or []:
        if not isinstance(rc, dict):
            continue
        rtype = rc.get("type") or ""
        actions = list((rc.get("change") or {}).get("actions") or [])
        if actions in QUIET_ACTIONS:
            continue
        change = Change(str(rc.get("address") or rtype), rtype, _label(actions))
        if rtype in GATED_TYPES:
            gated.append(change)
        elif rtype in INFO_TYPES:
            info.append(change)
    return Scope(sorted(gated, key=lambda c: c.address), sorted(info, key=lambda c: c.address))


def load(path: str) -> Scope:
    try:
        with open(path, encoding="utf-8") as fh:
            plan = json.load(fh)
    except FileNotFoundError:
        return Scope([], [], error=f"plan JSON not found: {path}")
    except json.JSONDecodeError as exc:
        return Scope([], [], error=f"plan JSON is not valid JSON ({exc.msg} at line {exc.lineno})")
    return find_scope(plan)


def render(scope: Scope) -> str:
    lines = []
    if scope.error:
        lines.append(f"Job-idle scope: ERROR, {scope.error}. The job-idle gate runs (fail closed).")
    elif scope.gated:
        lines.append(f"Job-idle scope: the plan touches {len(scope.gated)} resource(s) that can restart a task or the "
                     f"DB. The job-idle gate runs before the apply.")
    else:
        lines.append("Job-idle scope: no ECS service, cluster or RDS change. The job-idle gate is skipped.")
    for c in scope.gated:
        lines.append(f"- gated: `{c.address}` ({c.actions})")
    for c in scope.info:
        lines.append(f"- info: `{c.address}` ({c.actions}): new revision only, nothing restarts now; the next Deploy "
                     f"Dev copies it (compare its env names with the running revision)")
    return "\n".join(lines)


def main(argv: Optional[list] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("plan_json", help="output of `terraform show -json <planfile>`")
    ap.add_argument("--github-output", help="append gated=true|false to this file ($GITHUB_OUTPUT)")
    ap.add_argument("--summary", help="append the report to this file ($GITHUB_STEP_SUMMARY)")
    args = ap.parse_args(argv)

    scope = load(args.plan_json)
    text = render(scope)
    print(text)
    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as fh:
            fh.write(f"gated={'true' if scope.needs_gate else 'false'}\n")
    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as fh:
            fh.write("### Job-idle scope\n\n" + text + "\n\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
