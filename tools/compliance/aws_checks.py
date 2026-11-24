#!/usr/bin/env python3
"""AA-1173 (S290, compliance readiness phase 2) — the nightly AWS read-only checks of Platform › Compliance.

The workflow "Compliance AWS" (.github/workflows/compliance-aws.yml) runs this on main every night with the role
aa-cis-<env>-compliance-evidence (SecurityAudit + ViewOnlyAccess + a few reads; accounts/aa365/compliance_evidence.tf)
and seals the bundle it writes into the Object Lock evidence bucket (tools/compliance/seal.py, source aws_nightly). The
CIS API ingests it (AA-CIS-App api/services/compliance_store.py). Root advisory
docs/audits/2026-11-21-S287-compliance-tracking/README.md section 4 C.4 (the AWS row) and the S287 follow-ups (the WAF
rate rule, alarms on the alerts topic).

Checks (one bundle row each; pass | fail, error when the read failed). These are security invariants (logging on, MFA,
nothing open to the internet but the web ports...), graded here; the one tolerance the business may set (failing
Prowler findings) is a CIS setting on the weekly scan. Names and values the checks need (the alerts topic name, the
web ports, the regions) are in tools/compliance/aws_checks.toml, never in this file:

  aws_cloudtrail_logging        a multi-region trail is logging with log file validation on
  aws_s3_account_public_block   the account S3 Block Public Access has all four settings on
  aws_kms_rotation              every enabled symmetric customer key rotates
  aws_iam_mfa                   the root user has MFA and no access key; no IAM user with a console password lacks MFA
  aws_open_security_groups      no security group allows 0.0.0.0/0 or ::/0 on a port other than the web ports
  aws_access_analyzer           an external access analyzer exists and has no active finding
  aws_rds_protection            every DB instance is encrypted, keeps backups and has deletion protection
  aws_ecr_immutable_scan        every repository has immutable tags and scan on push (or registry scanning)
  aws_waf_rate_rule             every web ACL (regional and CloudFront) has a rate-based rule
  aws_alerts_topic_alarms       alarms send to the alerts topic and none of those has its actions switched off
  aws_audit_manager_off         Audit Manager is not enabled (it bills per assessment; advisory D.3)

Public repos: the bundle carries counts and resource NAMES only (no account id, no ARN, no security group id, no user
name); every text goes through tools/docs/aws_mask.py and :func:`assert_publishable` refuses the file otherwise. The
run prints the counts by status only.

    python3 tools/compliance/aws_checks.py --out _out/bundle.json        # AWS credentials in the environment

Stdlib (+ tomllib) and the AWS CLI. Exit 0 = file written (failing checks are results), 2 = forbidden text.
"""
from __future__ import annotations

import argparse
import base64
import csv
import io
import json
import os
import re
import subprocess
import sys
import time
import tomllib
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Optional

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "docs"))
import aws_mask  # noqa: E402

CONFIG = Path(__file__).with_name("aws_checks.toml")
FORMAT = 1
SOURCE = "aws_nightly"
LINK = "https://github.com/AdventureAsia365-Ecosys/AA-CIS-Infra/blob/main/tools/compliance/aws_checks.py"
_CODE = re.compile(r"An error occurred \(([A-Za-z0-9]+)\)")
FORBIDDEN = (
    (re.compile(r"(?<![0-9A-Za-z])\d{12}(?![0-9A-Za-z])"), "an account ID"),
    (re.compile(r"arn:aws", re.I), "an ARN"),
    (re.compile(r"s3://", re.I), "an S3 URI"),
    (re.compile(r"\bsg-[0-9a-f]{8,}\b"), "a security group id"),
    (re.compile(r"[\w.+-]+@[\w-]+\.[\w.]+"), "an e-mail address"),
)

Runner = Callable[[list], object]


class AwsError(Exception):
    """A read failed; the message names the call and the AWS error code only."""


def aws_cli(args: list) -> object:
    proc = subprocess.run(["aws", *args, "--output", "json"], capture_output=True, text=True, timeout=180,
                          stdin=subprocess.DEVNULL)
    if proc.returncode != 0:
        m = _CODE.search(proc.stderr or "")
        raise AwsError(f"{args[0]} {args[1]}: {m.group(1) if m else 'failed'}")
    return json.loads(proc.stdout or "null")


def load_config(path: Path = CONFIG) -> dict:
    return tomllib.loads(path.read_text(encoding="utf-8"))


def _row(check_id: str, status: str, summary: str, detail: Optional[dict] = None) -> dict:
    return {"check_id": check_id, "status": status, "summary": aws_mask.mask_text(summary)[:300],
            "detail": json.loads(aws_mask.mask_text(json.dumps(detail or {}))), "link": LINK}


def _names(items: list, limit: int = 20) -> list:
    return sorted(str(i) for i in items)[:limit]


# ── checks ──────────────────────────────────────────────────────────────────────────────────────────────────────────


def cloudtrail(run: Runner, cfg: dict) -> dict:
    trails = (run(["cloudtrail", "describe-trails", "--include-shadow-trails"]) or {}).get("trailList") or []
    good = []
    for t in trails:
        if not (t.get("IsMultiRegionTrail") and t.get("LogFileValidationEnabled")):
            continue
        status = run(["cloudtrail", "get-trail-status", "--name", t["TrailARN"]]) or {}
        if status.get("IsLogging"):
            good.append(t.get("Name"))
    detail = {"trails": len(trails), "multi_region_logging_validated": len(good), "names": _names(good)}
    if good:
        return _row("aws_cloudtrail_logging", "pass", f"{len(good)} multi-region trail(s) logging with validation",
                    detail)
    return _row("aws_cloudtrail_logging", "fail", "no multi-region trail is logging with log file validation", detail)


def s3_public_block(run: Runner, cfg: dict, account: str) -> dict:
    conf = (run(["s3control", "get-public-access-block", "--account-id", account]) or {}).get(
        "PublicAccessBlockConfiguration") or {}
    keys = ("BlockPublicAcls", "IgnorePublicAcls", "BlockPublicPolicy", "RestrictPublicBuckets")
    off = [k for k in keys if not conf.get(k)]
    if off:
        return _row("aws_s3_account_public_block", "fail", f"{len(off)} of 4 settings off: {', '.join(off)}",
                    {"off": off})
    return _row("aws_s3_account_public_block", "pass", "all four account settings on", {"off": []})


def kms_rotation(run: Runner, cfg: dict) -> dict:
    keys = [k["KeyId"] for k in (run(["kms", "list-keys"]) or {}).get("Keys") or []]
    customer, not_rotating = 0, []
    for kid in keys:
        meta = (run(["kms", "describe-key", "--key-id", kid]) or {}).get("KeyMetadata") or {}
        if meta.get("KeyManager") != "CUSTOMER" or meta.get("KeyState") != "Enabled" \
                or meta.get("KeySpec", "SYMMETRIC_DEFAULT") != "SYMMETRIC_DEFAULT" or meta.get("Origin") == "EXTERNAL":
            continue
        customer += 1
        if not (run(["kms", "get-key-rotation-status", "--key-id", kid]) or {}).get("KeyRotationEnabled"):
            not_rotating.append(kid[:8])
    detail = {"customer_keys": customer, "not_rotating": len(not_rotating)}
    if not_rotating:
        return _row("aws_kms_rotation", "fail", f"{len(not_rotating)} of {customer} customer key(s) do not rotate",
                    detail)
    return _row("aws_kms_rotation", "pass", f"{customer} customer key(s), all rotating", detail)


def iam_mfa(run: Runner, cfg: dict, sleep: Callable[[float], None] = time.sleep) -> dict:
    # IAM builds the report asynchronously: generate answers STARTED / INPROGRESS until it is COMPLETE. The number of
    # polls and the pause are in aws_checks.toml (a CI tool has no Platform › Settings; AA-1173 follow-up).
    polls = int(cfg.get("credential_report_polls", 10))
    for i in range(max(polls, 1)):
        if ((run(["iam", "generate-credential-report"]) or {}).get("State")) == "COMPLETE":
            break
        if i + 1 < polls:
            sleep(float(cfg.get("credential_report_pause_seconds", 3)))
    else:
        raise AwsError("iam generate-credential-report: ReportNotComplete")
    report = run(["iam", "get-credential-report"]) or {}
    text = base64.b64decode(report.get("Content") or b"").decode("utf-8", "replace")
    rows = list(csv.DictReader(io.StringIO(text)))
    root = next((r for r in rows if r.get("user") == "<root_account>"), None)
    users = [r for r in rows if r.get("user") != "<root_account>"]
    console_no_mfa = sum(1 for r in users if r.get("password_enabled") == "true" and r.get("mfa_active") != "true")
    root_mfa = bool(root and root.get("mfa_active") == "true")
    root_keys = bool(root and "true" in (root.get("access_key_1_active"), root.get("access_key_2_active")))
    detail = {"users": len(users), "console_users_without_mfa": console_no_mfa, "root_mfa": root_mfa,
              "root_access_keys": root_keys}
    problems = []
    if not root_mfa:
        problems.append("root without MFA")
    if root_keys:
        problems.append("root access key active")
    if console_no_mfa:
        problems.append(f"{console_no_mfa} console user(s) without MFA")
    if problems:
        return _row("aws_iam_mfa", "fail", "; ".join(problems), detail)
    return _row("aws_iam_mfa", "pass", f"root MFA on, no root key, {len(users)} IAM user(s) checked", detail)


def open_security_groups(run: Runner, cfg: dict) -> dict:
    web = set(cfg["web_ports"])
    groups = (run(["ec2", "describe-security-groups"]) or {}).get("SecurityGroups") or []
    bad = set()
    for g in groups:
        for p in g.get("IpPermissions") or []:
            world = any(r.get("CidrIp") == "0.0.0.0/0" for r in p.get("IpRanges") or []) or \
                any(r.get("CidrIpv6") == "::/0" for r in p.get("Ipv6Ranges") or [])
            if not world:
                continue
            lo, hi = p.get("FromPort"), p.get("ToPort")
            if p.get("IpProtocol") == "-1" or lo is None or not (lo == hi and lo in web):
                bad.add(g.get("GroupName") or "unnamed")
    detail = {"groups": len(groups), "open_beyond_web": len(bad), "names": _names(bad)}
    if bad:
        return _row("aws_open_security_groups", "fail", f"{len(bad)} group(s) open to the internet beyond the web "
                    "ports", detail)
    return _row("aws_open_security_groups", "pass", f"{len(groups)} group(s), none open beyond the web ports", detail)


def access_analyzer(run: Runner, cfg: dict) -> dict:
    analyzers = [a for a in (run(["accessanalyzer", "list-analyzers"]) or {}).get("analyzers") or []
                 if a.get("type") in ("ACCOUNT", "ORGANIZATION") and a.get("status") == "ACTIVE"]
    if not analyzers:
        return _row("aws_access_analyzer", "fail", "no active external access analyzer", {"analyzers": 0})
    active = 0
    for a in analyzers:
        found = run(["accessanalyzer", "list-findings-v2", "--analyzer-arn", a["arn"],
                     "--filter", '{"status": {"eq": ["ACTIVE"]}}']) or {}
        active += len(found.get("findings") or [])
    detail = {"analyzers": len(analyzers), "active_findings": active}
    if active:
        return _row("aws_access_analyzer", "fail", f"{active} active external access finding(s)", detail)
    return _row("aws_access_analyzer", "pass", "no active external access finding", detail)


def rds_protection(run: Runner, cfg: dict) -> dict:
    dbs = (run(["rds", "describe-db-instances"]) or {}).get("DBInstances") or []
    bad = {}
    for d in dbs:
        miss = [n for n, ok in (("encryption", d.get("StorageEncrypted")),
                                ("backups", (d.get("BackupRetentionPeriod") or 0) > 0),
                                ("deletion_protection", d.get("DeletionProtection"))) if not ok]
        if miss:
            bad[d.get("DBInstanceIdentifier") or "unnamed"] = miss
    detail = {"instances": len(dbs), "missing": bad}
    if bad:
        return _row("aws_rds_protection", "fail", f"{len(bad)} of {len(dbs)} instance(s) miss a protection", detail)
    return _row("aws_rds_protection", "pass", f"{len(dbs)} instance(s) encrypted, backed up, deletion protected",
                detail)


def ecr_repos(run: Runner, cfg: dict) -> dict:
    repos = (run(["ecr", "describe-repositories"]) or {}).get("repositories") or []
    reg = (run(["ecr", "get-registry-scanning-configuration"]) or {}).get("scanningConfiguration") or {}
    registry_scan = reg.get("scanType") == "ENHANCED" or any(
        r.get("scanFrequency") in ("SCAN_ON_PUSH", "CONTINUOUS_SCAN") for r in reg.get("rules") or [])
    mutable = [r["repositoryName"] for r in repos if r.get("imageTagMutability") != "IMMUTABLE"]
    no_scan = [] if registry_scan else [r["repositoryName"] for r in repos
                                        if not (r.get("imageScanningConfiguration") or {}).get("scanOnPush")]
    detail = {"repositories": len(repos), "mutable": _names(mutable), "no_scan_on_push": _names(no_scan),
              "registry_scanning": registry_scan}
    if mutable or no_scan:
        return _row("aws_ecr_immutable_scan", "fail", f"{len(mutable)} mutable, {len(no_scan)} without scan on push "
                    f"of {len(repos)} repositories", detail)
    return _row("aws_ecr_immutable_scan", "pass", f"{len(repos)} repositories immutable and scanned", detail)


def waf_rate_rule(run: Runner, cfg: dict) -> dict:
    acls, without = 0, []
    for scope, region in (("REGIONAL", cfg["region"]), ("CLOUDFRONT", "us-east-1")):
        for acl in (run(["wafv2", "list-web-acls", "--scope", scope, "--region", region]) or {}).get("WebACLs") or []:
            acls += 1
            full = (run(["wafv2", "get-web-acl", "--scope", scope, "--region", region, "--name", acl["Name"],
                         "--id", acl["Id"]]) or {}).get("WebACL") or {}
            if not any("RateBasedStatement" in (r.get("Statement") or {}) for r in full.get("Rules") or []):
                without.append(acl["Name"])
    detail = {"web_acls": acls, "without_rate_rule": _names(without)}
    if not acls:
        return _row("aws_waf_rate_rule", "fail", "no web ACL found", detail)
    if without:
        return _row("aws_waf_rate_rule", "fail", f"{len(without)} of {acls} web ACL(s) have no rate-based rule",
                    detail)
    return _row("aws_waf_rate_rule", "pass", f"{acls} web ACL(s), each with a rate-based rule", detail)


def alerts_topic_alarms(run: Runner, cfg: dict) -> dict:
    suffix = cfg["alerts_topic_suffix"]
    alarms = []
    token: Optional[str] = None
    while True:
        args = ["cloudwatch", "describe-alarms", "--max-items", "500"]
        if token:
            args += ["--starting-token", token]
        page = run(args) or {}
        alarms += (page.get("MetricAlarms") or []) + (page.get("CompositeAlarms") or [])
        token = page.get("NextToken")
        if not token:
            break
    # the topic NAME (the last ARN field) ends with the suffix, e.g. "<prefix>-acp-alerts"
    routed = [a for a in alarms
              if any(str(x).rsplit(":", 1)[-1].endswith(suffix) for x in a.get("AlarmActions") or [])]
    disabled = [a.get("AlarmName") for a in routed if a.get("ActionsEnabled") is False]
    detail = {"alarms": len(alarms), "to_alerts_topic": len(routed), "actions_off": _names(disabled)}
    if not routed:
        return _row("aws_alerts_topic_alarms", "fail", "no alarm sends to the alerts topic", detail)
    if disabled:
        return _row("aws_alerts_topic_alarms", "fail", f"{len(disabled)} alarm(s) to the alerts topic have actions "
                    "off", detail)
    return _row("aws_alerts_topic_alarms", "pass", f"{len(routed)} alarm(s) send to the alerts topic", detail)


def audit_manager_off(run: Runner, cfg: dict) -> dict:
    status = (run(["auditmanager", "get-account-status"]) or {}).get("status")
    if status == "ACTIVE":
        return _row("aws_audit_manager_off", "fail", "Audit Manager is enabled (billed per assessment)",
                    {"status": status})
    return _row("aws_audit_manager_off", "pass", f"Audit Manager is {status or 'not enabled'}", {"status": status})


CHECKS = (("aws_cloudtrail_logging", cloudtrail), ("aws_s3_account_public_block", s3_public_block),
          ("aws_kms_rotation", kms_rotation), ("aws_iam_mfa", iam_mfa),
          ("aws_open_security_groups", open_security_groups), ("aws_access_analyzer", access_analyzer),
          ("aws_rds_protection", rds_protection), ("aws_ecr_immutable_scan", ecr_repos),
          ("aws_waf_rate_rule", waf_rate_rule), ("aws_alerts_topic_alarms", alerts_topic_alarms),
          ("aws_audit_manager_off", audit_manager_off))


def collect(run: Runner, cfg: dict) -> list:
    account = str((run(["sts", "get-caller-identity"]) or {}).get("Account") or "")
    rows = []
    for check_id, fn in CHECKS:
        try:
            rows.append(fn(run, cfg, account) if fn is s3_public_block else fn(run, cfg))
        except AwsError as exc:
            rows.append(_row(check_id, "error", f"read failed: {exc}"))
        except (KeyError, TypeError, ValueError) as exc:
            rows.append(_row(check_id, "error", f"unexpected answer ({type(exc).__name__})"))
    return rows


def bundle(rows: list, now: datetime) -> dict:
    run_ref = f"{os.environ.get('GITHUB_WORKFLOW', 'compliance-aws')} #{os.environ.get('GITHUB_RUN_NUMBER', '0')}"
    sha = os.environ.get("GITHUB_SHA") or None
    return {"format": FORMAT, "source": SOURCE, "collector": "AA-CIS-Infra compliance-aws (aws_checks.py)",
            "collector_version": sha if sha and re.fullmatch(r"[0-9a-f]{7,40}", sha) else None,
            "run_ref": run_ref[:120], "generated_at": now.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
            "checks": rows}


def assert_publishable(text: str) -> list:
    return [what for rx, what in FORBIDDEN if rx.search(text)]


def main(argv: Optional[list] = None, run: Runner = aws_cli) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--config", default=CONFIG, type=Path)
    a = ap.parse_args(argv)
    rows = collect(run, load_config(a.config))
    text = json.dumps(bundle(rows, datetime.now(timezone.utc)), indent=1, sort_keys=True) + "\n"
    leaks = assert_publishable(text)
    if leaks:
        print(f"aws_checks: refused to write the bundle: it carries {', '.join(sorted(set(leaks)))}", file=sys.stderr)
        return 2
    a.out.parent.mkdir(parents=True, exist_ok=True)
    a.out.write_text(text, encoding="utf-8")
    counts: dict = {}
    for r in rows:
        counts[r["status"]] = counts.get(r["status"], 0) + 1
    print(json.dumps({"checks": len(rows), "by_status": counts}, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
