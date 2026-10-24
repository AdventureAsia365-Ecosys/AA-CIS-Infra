"""AA-869 — expire manual RDS snapshots of the Dev instance after RETAIN_DAYS (DM-7.5).

Runs once a day (EventBridge Scheduler, rds_snapshot_expiry.tf). Stdlib + the runtime's bundled
boto3 only.

Rule
  Candidates: DBSnapshots with SnapshotType == "manual", Status == "available" and
  DBInstanceIdentifier in INSTANCE_ALLOWLIST. Shared/public snapshots are never listed
  (IncludeShared/IncludePublic stay False), automated ("rds:...") and AWS Backup
  ("awsbackup:...") snapshots are never candidates.
  Keep when ANY of:
    - the identifier starts with "keep-";
    - tag aa:retain == "keep" (case-insensitive, surrounding spaces ignored);
    - tag aa:retain-until is a YYYY-MM-DD date today or later (UTC);
    - tag aa:retain-until is malformed (fail safe: keep, and report it).
  Otherwise expire when aa:retain-until is in the past, or when the snapshot is older than
  RETAIN_DAYS (strictly: now - SnapshotCreateTime > RETAIN_DAYS days).
  Orphan guard (fail safe): a snapshot that would expire is KEPT, and reported, when its source
  instance no longer exists or was re-created (the snapshot's InstanceCreateTime differs from the
  live instance's). This covers the final snapshot RDS writes when the instance is deleted
  ("aa-cis-dev-db-final", modules/rds): it may be the only copy left. Tag it aa:retain=keep (or
  aa:retain-until) to keep it on purpose and silence the report.

Safety
  DRY_RUN: only the exact string "false" deletes; anything else (unset, "False", "0", "") reports.
  MAX_DELETES_PER_RUN: at most that many deletions per run (oldest first); the rest are reported
  as over_cap and wait for the next run.

Backup-copy age (AA-942, card CRM-14, design V1: erased data leaves every backup copy within 30 days)
  After the run, the age in days of the oldest manual snapshot each allowlisted instance still has (kept by a
  keep- name, an aa:retain tag or the orphan guard, held back by the cap, or a failed delete), counting only
  snapshots created on or after COPY_AGE_SINCE (the day the first crm migration could exist; older snapshots hold
  no CRM data), and the instance's automated backup retention in days, go to CloudWatch (METRICS_NAMESPACE,
  dimension DBInstanceIdentifier: BackupCopyMaxAgeDays, AutomatedBackupRetentionDays). An alarm fires above 30
  (rds_snapshot_expiry.tf). No namespace = no metrics.

Report
  One JSON log line per snapshot (identifier, instance, created, age_days, decision, reason) and
  a summary line. An SNS message goes to ALERT_TOPIC_ARN only when something was deleted, would
  be deleted (dry run), was held back by the cap, failed, carried a malformed tag, or was kept by
  the orphan guard.
"""

from __future__ import annotations

import json
import os
import re
from dataclasses import asdict, dataclass, field
from datetime import date, datetime, timedelta, timezone
from typing import Iterable

KEEP_PREFIX = "keep-"
TAG_RETAIN = "aa:retain"
TAG_RETAIN_UNTIL = "aa:retain-until"
_DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
# Never candidates, whatever the API returns.
_FOREIGN_PREFIXES = ("rds:", "awsbackup:")

# Decisions (final, after the cap and DRY_RUN are applied).
KEEP = "keep"
SKIP = "skip"  # not a candidate (wrong type, status or instance)
EXPIRE = "expire"  # pure rule result, before the cap / dry run
DELETED = "deleted"
WOULD_DELETE = "would_delete"
OVER_CAP = "over_cap"
ERROR = "error"


@dataclass
class Decision:
    identifier: str
    instance: str | None
    created: str | None
    age_days: float | None
    decision: str
    reason: str
    malformed_tag: bool = False
    orphan: bool = False
    _created_dt: datetime | None = field(default=None, repr=False, compare=False)

    def as_log(self) -> dict:
        d = asdict(self)
        d.pop("_created_dt", None)
        return d


# ── Pure helpers (no AWS) ────────────────────────────────────────────────────


def is_dry_run(value: str | None) -> bool:
    """Only the exact string "false" turns deletion on."""
    return value != "false"


def parse_allowlist(value: str | None) -> list[str]:
    return [v.strip() for v in (value or "").split(",") if v.strip()]


def _tags(snapshot: dict) -> dict[str, str]:
    return {t.get("Key", ""): t.get("Value", "") for t in snapshot.get("TagList") or []}


def _as_utc(value) -> datetime | None:
    if value is None:
        return None
    if isinstance(value, str):
        value = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)


def parse_retain_until(value: str) -> date | None:
    """YYYY-MM-DD -> date; anything else -> None (malformed)."""
    if not _DATE_RE.match(value):
        return None
    try:
        return date.fromisoformat(value)
    except ValueError:
        return None


def source_instance_problem(snapshot: dict, live_instances: dict[str, datetime | None]) -> str | None:
    """Why the snapshot's source instance is not the live one, or None when it is.

    live_instances maps each allowlisted identifier that exists now to its InstanceCreateTime
    (None when RDS has not set it yet). Missing data on either side counts as a problem (fail safe).
    """
    instance = snapshot.get("DBInstanceIdentifier")
    if instance not in live_instances:
        return f"source instance {instance!r} no longer exists"
    live_created = _as_utc(live_instances[instance])
    snap_instance_created = _as_utc(snapshot.get("InstanceCreateTime"))
    if live_created is None or snap_instance_created is None:
        return "cannot match the snapshot to the live instance (no InstanceCreateTime)"
    if live_created != snap_instance_created:
        return (
            f"source instance {instance!r} was re-created "
            f"(snapshot of the {snap_instance_created.isoformat()} instance)"
        )
    return None


def decide_one(snapshot: dict, *, now: datetime, retain_days: int, allowlist: Iterable[str],
               live_instances: dict[str, datetime | None]) -> Decision:
    """Apply the keep/expire rule to one DescribeDBSnapshots item. No AWS calls.

    live_instances: allowlisted instances that exist now -> InstanceCreateTime (orphan guard).
    """
    ident = snapshot.get("DBSnapshotIdentifier", "")
    instance = snapshot.get("DBInstanceIdentifier")
    created_dt = _as_utc(snapshot.get("SnapshotCreateTime"))
    age_days = round((now - created_dt).total_seconds() / 86400, 2) if created_dt else None

    def out(decision: str, reason: str, malformed: bool = False, orphan: bool = False) -> Decision:
        return Decision(
            identifier=ident,
            instance=instance,
            created=created_dt.isoformat() if created_dt else None,
            age_days=age_days,
            decision=decision,
            reason=reason,
            malformed_tag=malformed,
            orphan=orphan,
            _created_dt=created_dt,
        )

    # Candidate filter.
    if snapshot.get("SnapshotType") != "manual":
        return out(SKIP, f"snapshot type {snapshot.get('SnapshotType')!r} is not manual")
    if ident.startswith(_FOREIGN_PREFIXES):
        return out(SKIP, "automated or AWS Backup snapshot")
    if instance not in set(allowlist):
        return out(SKIP, f"instance {instance!r} not in allowlist")
    if snapshot.get("Status") != "available":
        return out(SKIP, f"status {snapshot.get('Status')!r} is not available")
    if created_dt is None:
        return out(KEEP, "no SnapshotCreateTime (fail safe)")

    tags = _tags(snapshot)
    raw_until = tags.get(TAG_RETAIN_UNTIL)
    until = parse_retain_until(raw_until) if raw_until is not None else None
    malformed = raw_until is not None and until is None

    # Keep rules (any one wins).
    if ident.startswith(KEEP_PREFIX):
        return out(KEEP, "identifier starts with keep-", malformed)
    if tags.get(TAG_RETAIN, "").strip().lower() == "keep":
        return out(KEEP, f"tag {TAG_RETAIN}=keep", malformed)
    if malformed:
        return out(KEEP, f"malformed tag {TAG_RETAIN_UNTIL}={raw_until!r} (fail safe)", True)
    today = now.date()
    if until is not None and until >= today:
        return out(KEEP, f"tag {TAG_RETAIN_UNTIL}={until.isoformat()} not reached")

    # Expire rules.
    if until is not None:
        expire_reason = f"tag {TAG_RETAIN_UNTIL}={until.isoformat()} is in the past"
    elif now - created_dt > timedelta(days=retain_days):
        expire_reason = f"older than {retain_days} days"
    else:
        return out(KEEP, f"younger than {retain_days} days")

    # Orphan guard: never expire the last copy of a deleted or replaced instance by age alone.
    problem = source_instance_problem(snapshot, live_instances)
    if problem:
        return out(KEEP, f"{expire_reason}, but {problem} (fail safe)", orphan=True)
    return out(EXPIRE, expire_reason)


def apply_cap_and_mode(decisions: list[Decision], *, max_deletes: int, dry_run: bool) -> list[Decision]:
    """Turn EXPIRE into WOULD_DELETE / pending delete / OVER_CAP, oldest first.

    In live mode the first max_deletes candidates keep decision EXPIRE (the caller deletes them
    and sets DELETED or ERROR); in dry run they become WOULD_DELETE. The rest become OVER_CAP.
    """
    expiring = sorted(
        (d for d in decisions if d.decision == EXPIRE),
        key=lambda d: (d._created_dt or datetime.min.replace(tzinfo=timezone.utc), d.identifier),
    )
    for i, d in enumerate(expiring):
        if i >= max_deletes:
            d.decision = OVER_CAP
            d.reason += f"; over cap MAX_DELETES_PER_RUN={max_deletes}"
        elif dry_run:
            d.decision = WOULD_DELETE
            d.reason += "; DRY_RUN"
    return decisions


def plan(snapshots: list[dict], *, now: datetime, retain_days: int, allowlist: Iterable[str],
         live_instances: dict[str, datetime | None], max_deletes: int, dry_run: bool) -> list[Decision]:
    allow = list(allowlist)
    decisions = [
        decide_one(s, now=now, retain_days=retain_days, allowlist=allow, live_instances=live_instances)
        for s in snapshots
    ]
    return apply_cap_and_mode(decisions, max_deletes=max_deletes, dry_run=dry_run)


def summarize(decisions: list[Decision], *, dry_run: bool) -> dict:
    counts: dict[str, int] = {}
    for d in decisions:
        counts[d.decision] = counts.get(d.decision, 0) + 1
    return {
        "event": "summary",
        "dry_run": dry_run,
        "counts": counts,
        "malformed_tags": [d.identifier for d in decisions if d.malformed_tag],
        "orphans_kept": [d.identifier for d in decisions if d.orphan],
    }


def needs_notification(decisions: list[Decision]) -> bool:
    return any(
        d.decision in (DELETED, WOULD_DELETE, OVER_CAP, ERROR) or d.malformed_tag or d.orphan
        for d in decisions
    )


def build_message(decisions: list[Decision], *, env_name: str, dry_run: bool) -> tuple[str, str]:
    mode = "DRY RUN" if dry_run else "LIVE"
    n = {k: sum(1 for d in decisions if d.decision == k) for k in (DELETED, WOULD_DELETE, OVER_CAP, ERROR)}
    malformed = [d for d in decisions if d.malformed_tag]
    orphans = [d for d in decisions if d.orphan]
    parts = []
    if n[DELETED]:
        parts.append(f"{n[DELETED]} deleted")
    if n[WOULD_DELETE]:
        parts.append(f"{n[WOULD_DELETE]} would delete")
    if n[OVER_CAP]:
        parts.append(f"{n[OVER_CAP]} over cap")
    if n[ERROR]:
        parts.append(f"{n[ERROR]} failed")
    if malformed:
        parts.append(f"{len(malformed)} malformed tag")
    if orphans:
        parts.append(f"{len(orphans)} kept, source instance gone")
    subject = f"[{env_name}] RDS snapshot expiry ({mode}): " + ", ".join(parts or ["nothing to do"])
    lines = [f"RDS manual snapshot expiry, {mode}, {env_name}.", ""]
    for d in decisions:
        if d.decision in (DELETED, WOULD_DELETE, OVER_CAP, ERROR) or d.malformed_tag or d.orphan:
            lines.append(f"- {d.decision}: {d.identifier} (created {d.created}, {d.age_days} d) - {d.reason}")
    lines += [
        "",
        "Keep a snapshot: name it keep-..., or tag aa:retain=keep, or aa:retain-until=YYYY-MM-DD.",
        "Rule: AA-869 / DM-7.5 (AA-CIS-Infra accounts/aa365/rds_snapshot_expiry.tf).",
    ]
    return subject[:100], "\n".join(lines)


COPY_AGE_METRIC = "BackupCopyMaxAgeDays"
RETENTION_METRIC = "AutomatedBackupRetentionDays"


def copy_ages(decisions: list[Decision], allowlist: Iterable[str], since: datetime | None) -> dict[str, float]:
    """Oldest manual snapshot (days) each allowlisted instance still holds after the run; 0 when none.

    Deleted and skipped snapshots do not count; snapshots created before ``since`` do not either.
    """
    ages = {i: 0.0 for i in allowlist}
    for d in decisions:
        if d.instance not in ages or d.age_days is None or d.decision in (DELETED, SKIP):
            continue
        if since is not None and d._created_dt is not None and d._created_dt < since:
            continue
        ages[d.instance] = max(ages[d.instance], d.age_days)
    return ages


def metric_data(ages: dict[str, float], retention: dict[str, int], now: datetime) -> list[dict]:
    data = []
    for instance, age in sorted(ages.items()):
        dims = [{"Name": "DBInstanceIdentifier", "Value": instance}]
        data.append({"MetricName": COPY_AGE_METRIC, "Dimensions": dims, "Timestamp": now, "Value": float(age),
                     "Unit": "None"})
        if instance in retention:
            data.append({"MetricName": RETENTION_METRIC, "Dimensions": dims, "Timestamp": now,
                         "Value": float(retention[instance]), "Unit": "None"})
    return data


def parse_since(value: str | None) -> datetime | None:
    if not value:
        return None
    day = parse_retain_until(value)
    if day is None:
        raise ValueError(f"COPY_AGE_SINCE must be YYYY-MM-DD, got {value!r}")
    return datetime(day.year, day.month, day.day, tzinfo=timezone.utc)


# ── AWS side ─────────────────────────────────────────────────────────────────


def _log(obj: dict) -> None:
    print(json.dumps(obj, default=str, sort_keys=True))


def _int_env(env: dict, name: str, default: int, minimum: int) -> int:
    raw = env.get(name, str(default))
    try:
        value = int(raw)
    except ValueError as exc:
        raise ValueError(f"{name} must be an integer, got {raw!r}") from exc
    if value < minimum:
        raise ValueError(f"{name} must be >= {minimum}, got {value}")
    return value


def list_manual_snapshots(rds) -> list[dict]:
    out: list[dict] = []
    for page in rds.get_paginator("describe_db_snapshots").paginate(
        SnapshotType="manual", IncludeShared=False, IncludePublic=False
    ):
        out.extend(page.get("DBSnapshots", []))
    # DescribeDBSnapshots returns TagList; fall back to ListTagsForResource if it ever does not.
    for s in out:
        if "TagList" not in s and s.get("DBSnapshotArn"):
            s["TagList"] = rds.list_tags_for_resource(ResourceName=s["DBSnapshotArn"]).get("TagList", [])
    return out


def backup_retention(rds, allowlist: Iterable[str]) -> dict[str, int]:
    """Allowlisted instances that exist now -> BackupRetentionPeriod (days). Missing -> left out."""
    out: dict[str, int] = {}
    for ident in allowlist:
        try:
            resp = rds.describe_db_instances(DBInstanceIdentifier=ident)
        except Exception as exc:  # noqa: BLE001 — botocore ClientError; tests use no boto3
            code = (getattr(exc, "response", None) or {}).get("Error", {}).get("Code")
            if code in ("DBInstanceNotFound", "DBInstanceNotFoundFault"):
                continue
            raise
        for inst in resp.get("DBInstances", []):
            if inst.get("DBInstanceIdentifier") == ident and inst.get("BackupRetentionPeriod") is not None:
                out[ident] = int(inst["BackupRetentionPeriod"])
    return out


def describe_live_instances(rds, allowlist: Iterable[str]) -> dict[str, datetime | None]:
    """Allowlisted instances that exist now -> InstanceCreateTime. Not found -> left out.

    Any other error propagates: without this answer the orphan guard cannot run, so the
    invocation fails (Errors alarm) instead of deleting blind.
    """
    live: dict[str, datetime | None] = {}
    for ident in allowlist:
        try:
            resp = rds.describe_db_instances(DBInstanceIdentifier=ident)
        except Exception as exc:  # noqa: BLE001 — botocore ClientError; tests use no boto3
            code = (getattr(exc, "response", None) or {}).get("Error", {}).get("Code")
            if code in ("DBInstanceNotFound", "DBInstanceNotFoundFault"):
                continue
            raise
        for inst in resp.get("DBInstances", []):
            if inst.get("DBInstanceIdentifier") == ident:
                live[ident] = inst.get("InstanceCreateTime")
    return live


def run(rds, sns, *, env: dict, now: datetime, cloudwatch=None) -> dict:
    dry_run = is_dry_run(env.get("DRY_RUN"))
    namespace = env.get("METRICS_NAMESPACE", "")
    since = parse_since(env.get("COPY_AGE_SINCE"))
    retain_days = _int_env(env, "RETAIN_DAYS", 30, 1)
    max_deletes = _int_env(env, "MAX_DELETES_PER_RUN", 3, 0)
    allowlist = parse_allowlist(env.get("INSTANCE_ALLOWLIST"))
    if not allowlist:
        raise ValueError("INSTANCE_ALLOWLIST is empty")
    topic = env.get("ALERT_TOPIC_ARN", "")
    env_name = env.get("ENV_NAME", "dev")

    decisions = plan(
        list_manual_snapshots(rds), now=now, retain_days=retain_days, allowlist=allowlist,
        live_instances=describe_live_instances(rds, allowlist), max_deletes=max_deletes,
        dry_run=dry_run,
    )

    if not dry_run:
        # Oldest first, the same order apply_cap_and_mode used to pick them.
        # (EXPIRE always has a create time; SKIP rows may not, so filter before sorting.)
        pending = sorted((d for d in decisions if d.decision == EXPIRE), key=lambda d: (d._created_dt, d.identifier))
        for d in pending:
            try:
                rds.delete_db_snapshot(DBSnapshotIdentifier=d.identifier)
                d.decision = DELETED
            except Exception as exc:  # noqa: BLE001 — report and continue with the next one
                d.decision = ERROR
                d.reason += f"; delete failed: {type(exc).__name__}"

    for d in decisions:
        _log({"event": "decision", **d.as_log()})
    summary = summarize(decisions, dry_run=dry_run)
    _log(summary)

    if needs_notification(decisions):
        if not topic:
            raise ValueError("ALERT_TOPIC_ARN is empty but there is something to report")
        subject, message = build_message(decisions, env_name=env_name, dry_run=dry_run)
        sns.publish(TopicArn=topic, Subject=subject, Message=message)
        summary["notified"] = True

    if namespace and cloudwatch is not None:
        ages = copy_ages(decisions, allowlist, since)
        retention = backup_retention(rds, allowlist)
        cloudwatch.put_metric_data(Namespace=namespace, MetricData=metric_data(ages, retention, now))
        summary["copy_age_days"] = ages
        summary["backup_retention_days"] = retention
        _log({"event": "copy_age", "copy_age_days": ages, "backup_retention_days": retention})

    errors = [d.identifier for d in decisions if d.decision == ERROR]
    if errors:
        # Fail the invocation so the Errors alarm fires (async retries are off in Terraform).
        raise RuntimeError(f"snapshot deletion failed for: {', '.join(errors)}")
    return summary


def handler(event, context):  # noqa: ARG001 — Lambda signature
    import boto3  # bundled with the Lambda runtime; imported here so tests need no boto3

    return run(
        boto3.client("rds"), boto3.client("sns"), env=dict(os.environ), now=datetime.now(timezone.utc),
        cloudwatch=boto3.client("cloudwatch"),
    )
