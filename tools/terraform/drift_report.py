#!/usr/bin/env python3
"""Scheduled Terraform drift report (AA-879 part B).

Reads the machine-readable log of `terraform plan -detailed-exitcode -json` (one JSON message per line) for one
Terraform root plus the plan's exit code, and writes a short report to the job summary:

  exit 0  in sync: the plan of `main` against the live account is empty                    -> report exit 0
  exit 2  not in sync: lists each resource Terraform saw changed outside Terraform
          (`resource_drift`), each change an apply of `main` would make (`planned_change`)
          and each output that would change                                                 -> report exit 1
  exit 1  the plan failed: lists the error diagnostics (summary + a short detail)           -> report exit 1

Only resource addresses, actions and error text reach the summary or the log. No attribute value, no plan file, no
diagnostic snippet: the plan log stays in RUNNER_TEMP and the workflow deletes it. Everything written goes through
tools/docs/aws_mask.py (account ids, ARNs and EC2 ids masked; this repo is public and so are its run logs).

Exit codes of this script: 0 in sync, 1 drift or plan error (the job fails, GitHub e-mails it), 3 bad input (log
missing, exit code not 0/1/2).

AA-1004: two more modes, for roots whose plan text must never reach a public log (accounts/management: e-mail
addresses, member account ids). The workflow then runs Terraform with -json into RUNNER_TEMP and prints only this
report:
  --mode plan    a PR plan or the plan step of an apply: exit 0 (no changes) and exit 2 (changes, listed) both
                 report 0; exit 1 (plan failed) reports 1.
  --mode apply   the JSON log of applying a saved plan: exit 0 lists what was applied and reports 0; exit 1 lists
                 the errors and reports 1.
E-mail addresses are masked (`{email}`) in every mode, besides the AWS identifiers aws_mask.py masks, and the index
key of an aws_identitystore_* address is redacted (`aws_identitystore_user.this[{key}]`).
--digest-out FILE writes the SHA-256 of the sorted "address<TAB>action" list of the planned resource and output
changes (no values): the management apply job compares the reviewed plan's digest with its own re-plan's.

Usage (the workflow, per root):
  terraform -chdir=accounts/aa365 plan -lock=false -input=false -detailed-exitcode -json > "$RUNNER_TEMP/plan.jsonl"
  python3 -B tools/terraform/drift_report.py --plan-log "$RUNNER_TEMP/plan.jsonl" --exit-code $? \
      --root accounts/aa365 [--summary "$GITHUB_STEP_SUMMARY"]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from dataclasses import dataclass, field
from typing import Iterable, Optional

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "docs"))
import aws_mask  # noqa: E402

DETAIL_MAX = 400
LIST_MAX = 100  # rows per table; the rest is counted, not listed (a summary page has a size limit)
MODES = ("drift", "plan", "apply")
IDENTITYSTORE_KEY_RE = re.compile(r'(aws_identitystore_[a-z_]+\.[A-Za-z0-9_-]+)\[[^\]]*\]')
EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}")


class InputError(Exception):
    """The plan log cannot be read or the exit code is not a plan exit code."""


@dataclass
class PlanReport:
    drift: list[tuple[str, str]] = field(default_factory=list)      # (address, action) changed outside Terraform
    planned: list[tuple[str, str]] = field(default_factory=list)    # (address, action) an apply would make
    outputs: list[tuple[str, str]] = field(default_factory=list)    # (output name, action)
    applied: list[tuple[str, str]] = field(default_factory=list)    # (address, action) done by an apply (AA-1004)
    errors: list[tuple[str, str]] = field(default_factory=list)     # (summary, detail)
    change_summary: str = ""
    skipped_lines: int = 0


def _addr_action(msg: dict) -> Optional[tuple[str, str]]:
    change = msg.get("change") or {}
    res = change.get("resource") or {}
    addr = res.get("addr")
    if not isinstance(addr, str) or not addr:
        return None
    action = change.get("action")
    return addr, action if isinstance(action, str) and action else "?"


def parse_plan_log(lines: Iterable[str]) -> PlanReport:
    """Collect the messages the report needs; any other message type is ignored."""
    rep = PlanReport()
    for raw in lines:
        raw = raw.strip()
        if not raw:
            continue
        try:
            msg = json.loads(raw)
        except ValueError:
            rep.skipped_lines += 1
            continue
        if not isinstance(msg, dict):
            rep.skipped_lines += 1
            continue
        kind = msg.get("type")
        if kind == "resource_drift":
            item = _addr_action(msg)
            if item:
                rep.drift.append(item)
        elif kind == "planned_change":
            item = _addr_action(msg)
            if item and item[1] not in ("noop", "read"):
                rep.planned.append(item)
        elif kind == "apply_complete":
            hook = msg.get("hook") or {}
            addr = (hook.get("resource") or {}).get("addr")
            if isinstance(addr, str) and addr:
                action = hook.get("action")
                rep.applied.append((addr, action if isinstance(action, str) and action else "?"))
        elif kind == "outputs":
            for name, out in sorted((msg.get("outputs") or {}).items()):
                action = (out or {}).get("action") if isinstance(out, dict) else None
                if action and action != "noop":
                    rep.outputs.append((name, action))
        elif kind == "diagnostic":
            diag = msg.get("diagnostic") or {}
            if diag.get("severity") == "error":
                rep.errors.append((str(diag.get("summary") or msg.get("@message") or "error"),
                                   str(diag.get("detail") or "")))
        elif kind == "change_summary":
            rep.change_summary = str(msg.get("@message") or "")
    return rep


def _cell(text: str) -> str:
    text = IDENTITYSTORE_KEY_RE.sub(r"\1[{key}]", EMAIL_RE.sub("{email}", text))
    return aws_mask.mask_text(text).replace("|", "\\|").replace("\n", " ").strip()


def _table(title: str, rows: list[tuple[str, str]], head: tuple[str, str]) -> list[str]:
    out = [f"**{title}** ({len(rows)})", "", f"| {head[0]} | {head[1]} |", "|---|---|"]
    for a, b in rows[:LIST_MAX]:
        out.append(f"| `{_cell(a)}` | {_cell(b)} |")
    if len(rows) > LIST_MAX:
        out.append(f"| ... {len(rows) - LIST_MAX} more | |")
    out.append("")
    return out


def _errors(rep: PlanReport, what: str) -> list[str]:
    if not rep.errors:
        return [f"(No error diagnostic in the {what} log; read the run log of the {what} step.)", ""]
    rows = []
    for summary, detail in rep.errors:
        detail = _cell(detail)  # mask before cutting, so a cut never leaves half an ARN or account id
        short = detail if len(detail) <= DETAIL_MAX else detail[:DETAIL_MAX] + "..."
        rows.append((summary, short))
    return _table("Errors", rows, ("Error", "Detail"))


def _render_plan(root_m: str, exit_code: int, rep: PlanReport) -> tuple[int, list[str], list[str]]:
    """--mode plan (AA-1004): changes are not a failure, only a failed plan is."""
    lines = [f"### Terraform plan: `{root_m}`", ""]
    if exit_code == 0:
        return 0, lines + ["**No changes.** (exit 0)", ""], []
    if exit_code == 2:
        lines += ["**Changes** (exit 2). Addresses and actions only: this root's plan text is not printed.", ""]
        if rep.change_summary:
            lines += [f"`{_cell(rep.change_summary)}`", ""]
        if rep.drift:
            lines += _table("Changed outside Terraform", rep.drift, ("Resource", "Change seen"))
        if rep.planned:
            lines += _table("An apply would", rep.planned, ("Resource", "Action"))
        if rep.outputs:
            lines += _table("Outputs that would change", rep.outputs, ("Output", "Action"))
        return 0, lines, []
    lines += ["**Plan failed** (exit 1).", ""] + _errors(rep, "plan")
    first = _cell(rep.errors[0][0]) if rep.errors else "no diagnostic"
    return 1, lines, [f"::error title=Terraform plan failed::{root_m}: plan exit 1 ({first})"]


def _render_apply(root_m: str, exit_code: int, rep: PlanReport) -> tuple[int, list[str], list[str]]:
    """--mode apply (AA-1004): what an apply did, or why it failed."""
    lines = [f"### Terraform apply: `{root_m}`", ""]
    if exit_code == 0:
        lines += ["**Applied.**", ""]
        if rep.change_summary:
            lines += [f"`{_cell(rep.change_summary)}`", ""]
        if rep.applied:
            lines += _table("Applied", rep.applied, ("Resource", "Action"))
        return 0, lines, []
    lines += ["**Apply failed** (exit 1). Resources listed under Applied were changed before the error.", ""]
    if rep.applied:
        lines += _table("Applied", rep.applied, ("Resource", "Action"))
    lines += _errors(rep, "apply")
    first = _cell(rep.errors[0][0]) if rep.errors else "no diagnostic"
    return 1, lines, [f"::error title=Terraform apply failed::{root_m}: apply exit 1 ({first})"]


def render(root: str, exit_code: int, rep: PlanReport, mode: str = "drift") -> tuple[int, list[str], list[str]]:
    """Return (script exit code, summary Markdown lines, workflow annotation lines)."""
    root_m = _cell(root)
    if mode == "plan":
        return _render_plan(root_m, exit_code, rep)
    if mode == "apply":
        return _render_apply(root_m, exit_code, rep)
    lines = [f"### Terraform drift: `{root_m}`", ""]
    notes: list[str] = []
    if exit_code == 0:
        lines += ["**In sync.** The plan of `main` against the live account is empty (exit 0).", ""]
        return 0, lines, notes
    if exit_code == 2:
        lines += [
            "**Not in sync** (exit 2). Either something changed outside Terraform (drift), or `main` holds a change "
            "that was never applied. Read the tables, then: apply `main` (Terraform Apply Prod) when the code is "
            "right, or fix the code / revert the manual change when the live value is right. Rerun this workflow "
            "after; it must end in sync.",
            "",
        ]
        if rep.change_summary:
            lines += [f"`{_cell(rep.change_summary)}`", ""]
        if rep.drift:
            lines += _table("Changed outside Terraform", rep.drift, ("Resource", "Change seen"))
        if rep.planned:
            lines += _table("An apply of main would", rep.planned, ("Resource", "Action"))
        if rep.outputs:
            lines += _table("Outputs that would change", rep.outputs, ("Output", "Action"))
        if not (rep.drift or rep.planned or rep.outputs):
            lines += ["(The plan log named no resource; read the run log of the plan step.)", ""]
        n = len(rep.planned) + len(rep.outputs)
        notes.append(f"::error title=Terraform drift::{root_m}: plan not empty ({n} change(s), "
                     f"{len(rep.drift)} changed outside Terraform); see the job summary")
        return 1, lines, notes
    # exit 1: the plan itself failed
    lines += ["**Plan failed** (exit 1). Drift unknown for this root.", ""]
    lines += _errors(rep, "plan")
    first = _cell(rep.errors[0][0]) if rep.errors else "no diagnostic"
    notes.append(f"::error title=Terraform drift check failed::{root_m}: plan exit 1 ({first})")
    return 1, lines, notes


def plan_digest(rep: PlanReport) -> str:
    """SHA-256 of the sorted planned resource and output changes (address/name + action only)."""
    rows = sorted([f"resource\t{a}\t{b}" for a, b in rep.planned] + [f"output\t{a}\t{b}" for a, b in rep.outputs])
    return hashlib.sha256("\n".join(rows).encode("utf-8")).hexdigest()


def run(plan_log: str, exit_code: int, root: str, summary: Optional[str], mode: str = "drift",
        digest_out: Optional[str] = None) -> int:
    if mode not in MODES:
        raise InputError(f"mode {mode!r} is not one of {', '.join(MODES)}")
    if mode == "apply" and exit_code not in (0, 1):
        raise InputError(f"terraform apply exit code {exit_code} is not 0 or 1")
    if exit_code not in (0, 1, 2):
        raise InputError(f"terraform plan exit code {exit_code} is not 0, 1 or 2")
    try:
        with open(plan_log, encoding="utf-8") as fh:
            rep = parse_plan_log(fh)
    except OSError as exc:
        raise InputError(f"cannot read the plan log: {exc.__class__.__name__}") from exc
    code, lines, notes = render(root, exit_code, rep, mode)
    if digest_out:
        digest = plan_digest(rep)
        with open(digest_out, "w", encoding="utf-8") as fh:
            fh.write(digest + "\n")
        lines += [f"Plan digest (sorted addresses and actions): `{digest}`", ""]
    text = "\n".join(lines) + "\n"
    leaks = aws_mask.find_leaks(text + "\n".join(notes))
    if EMAIL_RE.search(text + "\n".join(notes)):
        leaks.append("an e-mail address")
    if leaks:  # fail closed: never write an unmasked id to a public summary or log
        raise InputError("report still holds unmasked AWS identifiers: " + "; ".join(leaks))
    if summary:
        with open(summary, "a", encoding="utf-8") as fh:
            fh.write(text)
    else:
        sys.stdout.write(text)
    for note in notes:
        print(note)
    return code


def main(argv: Optional[list[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--plan-log", required=True, help="output of terraform plan -json (JSON lines)")
    ap.add_argument("--exit-code", required=True, type=int, help="exit code of terraform plan -detailed-exitcode")
    ap.add_argument("--root", required=True, help="Terraform root directory, for the report title")
    ap.add_argument("--summary", help="append the Markdown report here (GITHUB_STEP_SUMMARY); stdout otherwise")
    ap.add_argument("--mode", default="drift", choices=MODES,
                    help="drift (default; exit 2 fails), plan (exit 2 = changes, not a failure) or apply (AA-1004)")
    ap.add_argument("--digest-out", help="write the SHA-256 of the sorted planned address/action list here (AA-1004)")
    args = ap.parse_args(argv)
    try:
        return run(args.plan_log, args.exit_code, args.root, args.summary, args.mode, args.digest_out)
    except InputError as exc:
        print(f"::error title=Terraform drift check failed::{args.root}: {exc}")
        return 3


if __name__ == "__main__":
    sys.exit(main())
