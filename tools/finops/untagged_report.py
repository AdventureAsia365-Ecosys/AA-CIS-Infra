#!/usr/bin/env python3
"""Untagged resources and untagged spend, for the monthly C8 review (tagging standard FIN-03, S271). Read only.

Two parts:

1. Resources (live): every resource the Resource Groups Tagging API returns in the given regions (free API), checked
   against the tagging standard's machine copy, tools/terraform/tag_policy.json (the same rules as the Terraform plan
   tag guard, except ManagedBy may also say manual / ci / aws here). Grouped by service and resource type, with the
   missing keys, values outside the list and old spellings. The API only returns resources that carry or once carried
   a tag: a resource that never had any tag does not show here (the Terraform plan guard covers those in Terraform).
2. Spend (stored, no new Cost Explorer call): the "untagged" row of the CIS FinOps bundle (tools/finops/collect_month.py
   in the root repo, the month's Cost Explorer data by `App` tag and service that CIS stores daily), so the review
   says how much of the month had no `App` tag and which services it came from. Root FIN-01 forbids a new script that
   calls Cost Explorer itself (DM-10.4): a new grouping goes into the CIS client.

The report masks account IDs and ARNs (tools/docs/aws_mask.py: the review is saved in the public root repo).

Credentials: the acc2 MFA admin profile, exported first (one line, inside `bash -c`; root steering):
  C=$(aws configure export-credentials --profile aa365-admin --format env-no-export </dev/null) ; grep -q '^AWS_ACCESS_KEY_ID=' <<<"$C" || exit 1 ; env -u AWS_PROFILE $(tr '\\n' ' ' <<<"$C") python3 tools/finops/untagged_report.py --bundle <cis-bundle> --out <report.md>

Usage:
  python3 tools/finops/untagged_report.py [--regions us-west-1,us-east-1] [--bundle FILE] [--month YYYY-MM]
                                          [--out report.md] [--json report.json] [--max-share 0.2]
Exit codes: 0 report written; 1 the untagged share of the month is above --max-share; 2 bad input or AWS error.
"""
from __future__ import annotations

import argparse
import dataclasses
import json
import os
import sys
from collections import Counter, defaultdict
from typing import Any, Callable, Iterable, Optional

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(REPO_ROOT, "tools", "terraform"))
sys.path.insert(0, os.path.join(REPO_ROOT, "tools", "docs"))

import aws_mask  # noqa: E402
import tag_guard  # noqa: E402

BUNDLE_MARKER = "FINOPS_BUNDLE "
DEFAULT_REGIONS = ("us-west-1", "us-east-1")  # us-east-1: CloudFront, the ACM certificates of CloudFront and Cognito
MAX_LISTED = 60

# Spend that AWS bills without a resource, so no tag can ever reach it (tagging standard, "What tags cannot reach").
UNTAGGABLE_HINTS = {
    "AWS Data Transfer": "data transfer between AZs, regions and to the internet is billed per account",
    "AWS Cost Explorer": "API requests (0.01 USD each) belong to no resource",
    "Tax": "tax lines carry no tag",
    "AWS Support (Business)": "support plan fee",
    "AWS Support (Developer)": "support plan fee",
    "Amazon Virtual Private Cloud": "public IPv4 addresses (0.005 USD per hour each) and endpoint hours bill to the VPC "
                                    "service; only the tagged EIP or endpoint resource carries a tag",
    "AmazonCloudWatch": "metrics, API requests and dashboards have no resource tag (log groups and alarms do)",
    "Amazon Bedrock": "on-demand model calls carry no tag; per-app LLM spend comes from the gateway ledger (DM-10.4)",
    "AWS Key Management Service": "request charges follow the key's tags; AWS managed keys carry none",
    "Amazon Route 53": "DNS queries; the hosted zone fee follows the zone's tags",
}


class InputError(Exception):
    """A bundle or argument cannot be used."""


# --- resources -----------------------------------------------------------------------------------------------------


def report_policy(path: str = tag_guard.DEFAULT_POLICY) -> tag_guard.Policy:
    """The plan guard's policy without the Terraform-only ManagedBy rule (a resource outside Terraform says so)."""
    return dataclasses.replace(tag_guard.load_policy(path), plan_values={})


def fetch_resources(client_for: Callable[[str], Any], regions: Iterable[str]) -> list[dict[str, Any]]:
    """[{arn, region, tags}] from resourcegroupstaggingapi:GetResources in every region (paginated)."""
    out: list[dict[str, Any]] = []
    for region in regions:
        client = client_for(region)
        token = ""
        while True:
            kwargs: dict[str, Any] = {"ResourcesPerPage": 100}
            if token:
                kwargs["PaginationToken"] = token
            page = client.get_resources(**kwargs)
            for item in page.get("ResourceTagMappingList", []):
                tags = {t["Key"]: t["Value"] for t in item.get("Tags", [])}
                out.append({"arn": item["ResourceARN"], "region": region, "tags": tags})
            token = page.get("PaginationToken") or ""
            if not token:
                break
    return out


_NAME_ONLY = {"sns": "topic", "sqs": "queue"}  # services whose ARN resource part is the bare name

# Kinds the Tagging API returns that bill nothing and need no tag: an ECS Exec / SSM session record (thousands of
# them), the account's payment card, a developer-tool profile. Listed in the report as a count only.
IGNORED_KINDS = {
    "ssm:session": "SSM / ECS Exec session records, no charge",
    "payments:payment-instrument": "the account's payment method",
    "codewhisperer:profile": "developer tool profile, billed per user",
}


def resource_kind(arn: str) -> str:
    """service:type of an ARN, e.g. ec2:security-group, lambda:function, s3:bucket, logs:log-group."""
    parts = arn.split(":", 5)
    if len(parts) < 6:
        return "unknown"
    service, resource = parts[2], parts[5].lstrip("/")
    if service == "s3" and "/" not in resource:
        return "s3:bucket"
    if service in _NAME_ONLY:
        return f"{service}:{_NAME_ONLY[service]}"
    cut = [i for i in (resource.find("/"), resource.find(":")) if i > 0]
    return f"{service}:{resource[:min(cut)] if cut else resource}"


def evaluate(resources: list[dict[str, Any]], policy: tag_guard.Policy) -> dict[str, Any]:
    """Per resource: the plan guard's checks; per kind: counts. Keys: total, compliant, by_kind, problems."""
    by_kind: dict[str, Counter] = defaultdict(Counter)
    problems: list[dict[str, Any]] = []
    ignored: Counter = Counter()
    for r in resources:
        kind = resource_kind(r["arn"])
        if kind in IGNORED_KINDS:
            ignored[kind] += 1
            continue
        found = tag_guard.check_tags(r["arn"], kind, r["tags"], set(), policy)
        by_kind[kind]["resources"] += 1
        if not found:
            by_kind[kind]["compliant"] += 1
            continue
        if any(v.kind == "missing" and v.detail == "App" for v in found):
            by_kind[kind]["no_app"] += 1
        for v in found:
            by_kind[kind][f"{v.kind}:{v.detail.split('=')[0].split(' ')[0]}"] += 1
        problems.append({"arn": r["arn"], "kind": kind, "region": r["region"],
                         "managed_by": r["tags"].get("ManagedBy", ""),
                         "problems": [f"{v.kind} {v.detail}" for v in found]})
    total = sum(c["resources"] for c in by_kind.values())
    compliant = sum(c["compliant"] for c in by_kind.values())
    return {"total": total, "compliant": compliant, "by_kind": {k: dict(v) for k, v in sorted(by_kind.items())},
            "problems": problems, "ignored": dict(sorted(ignored.items()))}


# --- spend ---------------------------------------------------------------------------------------------------------


def load_bundle(path: str) -> dict[str, Any]:
    """The CIS bundle of collect_month.py: the 'FINOPS_BUNDLE <json>' line of an ecsx.sh output, or the bare JSON."""
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except FileNotFoundError as exc:
        raise InputError(f"bundle not found: {path}") from exc
    line = next((ln for ln in text.splitlines() if ln.startswith(BUNDLE_MARKER)), None)
    try:
        data = json.loads(line[len(BUNDLE_MARKER):] if line is not None else text)
    except json.JSONDecodeError as exc:
        raise InputError(f"{path}: no FINOPS_BUNDLE line and not JSON ({exc.msg})") from exc
    if not isinstance(data, dict) or data.get("kind") != "finops_bundle" or data.get("part") != "cis":
        raise InputError(f"{path}: not a collect_month.py bundle with PART=cis")
    if not isinstance(data.get("months"), dict) or not data["months"]:
        raise InputError(f"{path}: the bundle has no months")
    return data


def untagged_spend(bundle: dict[str, Any], month: Optional[str]) -> dict[str, Any]:
    """Total acc2 spend, untagged spend and its services for one month of the bundle (default: the latest)."""
    months = sorted(bundle["months"])
    month = month or months[-1]
    if month not in bundle["months"]:
        raise InputError(f"month {month} is not in the bundle ({', '.join(months)})")
    cost = (bundle["months"][month] or {}).get("platform_cost") or {}
    aws = cost.get("aws") or {}
    if not aws.get("has_data", True):
        raise InputError(f"month {month}: the bundle has no Cost Explorer data")
    total = float(aws.get("total_usd") or 0.0)
    row = next((a for a in cost.get("apps", []) if a.get("kind") == "untagged"), None) or {}
    services = sorted(((s["service"], float(s["amount_usd"])) for s in row.get("services", [])),
                      key=lambda x: -x[1])
    untagged = float(row.get("aws_usd") or aws.get("untagged_usd") or 0.0)
    return {"month": month, "total_usd": round(total, 2), "untagged_usd": round(untagged, 2),
            "share": round(untagged / total, 4) if total else 0.0,
            "covered": f"{aws.get('covered_from')} to {aws.get('covered_to')}",
            "services": [{"service": s, "amount_usd": round(a, 2), "why": UNTAGGABLE_HINTS.get(s, "")}
                         for s, a in services]}


# --- report --------------------------------------------------------------------------------------------------------


def render(res: Optional[dict[str, Any]], spend: Optional[dict[str, Any]], regions: Iterable[str]) -> str:
    lines = ["# Untagged resources and spend", "",
             "Tagging standard: root `docs/architecture/tagging-standard.md` (FIN-03). Rules applied: "
             "`tools/terraform/tag_policy.json`. Read-only report for the monthly C8 review.", ""]
    if spend is not None:
        lines += [f"## Spend without an `App` tag, {spend['month']}", "",
                  f"acc2 total {spend['total_usd']:.2f} USD, untagged {spend['untagged_usd']:.2f} USD "
                  f"({spend['share'] * 100:.1f} %), Cost Explorer days {spend['covered']} (stored by CIS, no new call).",
                  "", "| Service | Untagged (USD) | Why no tag reaches it |", "|---|---|---|"]
        for s in spend["services"]:
            why = s["why"] or "taggable: find the resource below or tag it in Terraform"
            lines.append(f"| {s['service']} | {s['amount_usd']:.2f} | {why} |")
        lines.append("")
    if res is not None:
        lines += [f"## Resources ({', '.join(regions)})", "",
                  f"{res['total']} resources returned by the Tagging API, {res['compliant']} carry every mandatory "
                  f"key with an allowed value, {res['total'] - res['compliant']} do not. Not counted (no charge, no tag "
                  f"needed): {', '.join(f'{k} {n}' for k, n in res.get('ignored', {}).items()) or 'none'}.", "",
                  "| Service:type | Resources | Compliant | No `App` | Top problems |", "|---|---|---|---|---|"]
        for kind, c in res["by_kind"].items():
            top = sorted(((k, n) for k, n in c.items() if ":" in k), key=lambda x: -x[1])[:3]
            lines.append(f"| {kind} | {c.get('resources', 0)} | {c.get('compliant', 0)} | {c.get('no_app', 0)} | "
                         f"{', '.join(f'{k} ({n})' for k, n in top)} |")
        lines += ["", "### Resources to fix (first {})".format(MAX_LISTED), ""]
        for p in res["problems"][:MAX_LISTED]:
            lines.append(f"- `{p['arn']}` ({p['managed_by'] or 'no ManagedBy'}): {'; '.join(p['problems'][:4])}")
        if len(res["problems"]) > MAX_LISTED:
            lines.append(f"- ... and {len(res['problems']) - MAX_LISTED} more (see the JSON output)")
        lines.append("")
    lines += ["Next step per row: a Terraform resource gets its tags in Infra (the plan tag guard then keeps them); a "
              "resource outside Terraform is tagged by hand with ManagedBy = manual (or imported); spend no tag can "
              "reach stays a known line of the review.", ""]
    return aws_mask.mask_text("\n".join(lines), aws_mask.load_aliases())


def main(argv: Optional[Iterable[str]] = None, client_for: Optional[Callable[[str], Any]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--regions", default=",".join(DEFAULT_REGIONS), help="comma-separated regions to list")
    ap.add_argument("--bundle", help="CIS FinOps bundle (collect_month.py PART=cis output) for the spend part")
    ap.add_argument("--month", help="YYYY-MM of the bundle (default: its latest month)")
    ap.add_argument("--no-resources", action="store_true", help="skip the Tagging API part (spend only)")
    ap.add_argument("--policy", default=tag_guard.DEFAULT_POLICY)
    ap.add_argument("--out", help="write the Markdown report here (default: stdout)")
    ap.add_argument("--json", dest="json_out", help="also write the full result as JSON (masked)")
    ap.add_argument("--max-share", type=float, help="exit 1 when the untagged share of the month is above this")
    args = ap.parse_args(list(argv) if argv is not None else None)
    regions = [r.strip() for r in args.regions.split(",") if r.strip()]
    try:
        policy = report_policy(args.policy)
        spend = untagged_spend(load_bundle(args.bundle), args.month) if args.bundle else None
        res = None
        if not args.no_resources:
            if client_for is None:
                import boto3  # only for a live run; the tests pass client_for

                session = boto3.Session()
                client_for = lambda region: session.client("resourcegroupstaggingapi", region_name=region)  # noqa: E731
            res = evaluate(fetch_resources(client_for, regions), policy)
    except (InputError, tag_guard.InputError) as exc:
        print(f"untagged_report: {exc}", file=sys.stderr)
        return 2
    except Exception as exc:  # botocore errors: expired MFA, AccessDenied; never print credentials
        print(f"untagged_report: AWS call failed: {type(exc).__name__}: {str(exc)[:300]}", file=sys.stderr)
        return 2
    text = render(res, spend, regions)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(text)
    else:
        print(text)
    if args.json_out:
        with open(args.json_out, "w", encoding="utf-8") as fh:
            fh.write(aws_mask.mask_text(json.dumps({"resources": res, "spend": spend}, indent=1),
                                        aws_mask.load_aliases()) + "\n")
    if args.max_share is not None and spend is not None and spend["share"] > args.max_share:
        print(f"untagged share {spend['share']:.1%} is above {args.max_share:.1%}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
