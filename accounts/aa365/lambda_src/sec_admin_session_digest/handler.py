"""AA-873 (S263) — activity digest of every Identity Center ADMINISTRATOR session in this account.

The sign-in alert (security_sso_signin.tf, rules aa-sec-<env>-sso-admin-signin-*) e-mails when an administrator
session STARTS. This function, run every hour by EventBridge Scheduler (security_sso_session_digest.tf), sends a
SECOND e-mail once that session is over: what the session did. Stdlib + the runtime's bundled boto3 only.

Sessions
  CloudTrail LookupEvents (EventName = AssumeRoleWithSAML) in SAML_REGIONS (us-east-1, where Identity Center calls the
  global STS endpoint, and this region) over the last LOOKBACK_HOURS. A session is one successful event whose
  requestParameters.roleArn names an AWSReservedSSO_<set>_<hash> role with <set> in ADMIN_PERMISSION_SETS.
  start = eventTime; expires = responseElements.credentials.expiration (fallback start + durationSeconds, then
  start + 12 h, the longest Identity Center session).

Activity of a session
  LookupEvents by Username = the role session name in ACTIVITY_REGIONS (us-east-1 holds the global services: IAM,
  STS, Organizations, CloudFront, Route 53), from the session start (or the end of the previous digest) to now. When
  that finds none of the session's CLI calls, a second lookup by AccessKeyId (the key AssumeRoleWithSAML returned)
  covers them. An event belongs to the session when its identity is the same permission-set role (or the same access
  key). Two sessions of the same user on the same role overlap rarely (console + CLI); an event then goes to the
  session with its access key, else to the session whose start is its credential creationDate, else to the latest
  session started before it.

When a session is over (digest sent)
  - now >= expires + DELIVERY_LAG_MINUTES (CloudTrail delivers within ~15 min), or
  - no event for IDLE_MINUTES (the last event, or the start when there is none, is that old).
  A session closed by idleness stays open in the state until it expires: events that show up later send one more
  digest ("continued"), so nothing done after a pause is lost.

The e-mail (one per session per digest)
  Session name masked to the user's local part, permission set, start / end (UTC and ICT), source IPs (last octet
  masked; CloudTrail carries no country), counts per service, then every DELETE action, then every other WRITE action
  (time, service, eventName, resource NAMES only, errorCode), then read-only calls summarised by count. Every line
  goes through mask_text(): no account id (12-digit run), no ARN, no full e-mail address ever reaches the message.
  The same masked text is logged (one JSON line per digest), so CloudWatch shows the mail shape.

State (no duplicate digests)
  One small JSON object in the bronze bucket (STATE_BUCKET / STATE_KEY): CloudTrail eventID of each reported session
  -> start, expires, reported_through, closed. Written only after a digest is published (a few times a month), pruned
  past LOOKBACK_HOURS + 1 day. No user name, IP or key is stored.

Preview (read-only, for the live check)
  Event {"preview": true, "since": "<ISO>", "until": "<ISO>"}: looks at sessions started in that window, builds every
  digest (also for a session still open), logs it and returns it. No SNS publish, no state read or write.
"""

from __future__ import annotations

import ipaddress
import json
import os
import re
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

ICT = timezone(timedelta(hours=7))
MAX_SESSION = timedelta(hours=12)  # longest session an Identity Center permission set allows
STATE_VERSION = 1
SUBJECT_MAX = 100  # SNS e-mail subject limit
WRITE_LINES_MAX = 300  # write/delete lines listed per digest; the rest is counted
READ_LINES_MAX = 60  # read-only (service, eventName) rows listed per digest

# Verbs whose action removes or disables something; listed before the other writes.
_DELETE_VERBS = ("Delete", "Remove", "Terminate", "Detach", "Disable", "Revoke", "Deregister", "Purge", "Destroy",
                 "Stop", "Cancel", "Deactivate", "Disassociate", "Untag", "Reject", "Abort")
# Read verbs, used only when an event carries no readOnly flag.
_READ_VERBS = ("Get", "List", "Describe", "Head", "Lookup", "Search", "BatchGet", "Select", "Scan", "Query", "Check",
               "Validate", "Preview", "Estimate", "View", "Test", "Simulate", "Export", "Download", "Discover")
# requestParameters keys whose value names the resource, read when CloudTrail lists no Resources.
_NAME_KEYS = ("bucketName", "roleName", "policyName", "userName", "groupName", "functionName", "secretId", "tableName",
              "dBInstanceIdentifier", "dBSnapshotIdentifier", "clusterName", "cluster", "serviceName", "service",
              "instanceId", "keyId", "aliasName", "logGroupName", "stackName", "repositoryName", "ruleName", "name",
              "alarmName", "topicArn", "queueUrl", "distributionId", "hostedZoneId", "parameterName", "trailName",
              "detectorId", "analyzerName", "scheduleName", "taskDefinition", "groupId", "vpcId", "subnetId")

_ROLE_RE = re.compile(r"AWSReservedSSO_(?P<set>[A-Za-z0-9+=,.@-]+?)_[0-9a-fA-F]+$")
_ARN_RE = re.compile(r"arn:aws[a-zA-Z-]*:[^\s\"',;()<>\[\]{}]*")
_EMAIL_RE = re.compile(r"([A-Za-z0-9._%+-]+)@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}")
_ACCOUNT_RE = re.compile(r"(?<!\d)\d{12}(?!\d)")
_STS_EXPIRATION_FORMATS = ("%b %d, %Y, %I:%M:%S %p", "%b %d, %Y %I:%M:%S %p")


# ── Masking ─────────────────────────────────────────────────────────────────────────────────────────────────────────

def arn_resource_name(arn: str) -> str:
    """The resource NAME of an ARN: no partition, service, region or account.

    arn:aws:iam::<acct>:role/a/b/Name -> Name; arn:aws:s3:::bucket/key -> bucket/key;
    arn:aws:lambda:<r>:<acct>:function:fn -> fn; arn:aws:logs:<r>:<acct>:log-group:/x:* -> /x.
    """
    parts = arn.split(":", 5)
    if len(parts) < 6:
        return ""
    service, resource = parts[2], parts[5]
    if service == "s3":
        return resource
    if service == "logs" and resource.startswith("log-group:"):
        return resource[len("log-group:"):].split(":", 1)[0]
    if "/" in resource:
        return resource.rsplit("/", 1)[1] or resource
    if ":" in resource:
        return resource.split(":", 1)[1].split(":", 1)[0]
    return resource


def mask_text(text) -> str:
    """No ARN, account id or full e-mail address survives. ARNs become their resource name."""
    if text is None:
        return ""
    s = str(text)
    s = _ARN_RE.sub(lambda m: arn_resource_name(m.group(0)), s)
    s = _EMAIL_RE.sub(lambda m: f"{m.group(1)}@…", s)
    s = _ACCOUNT_RE.sub("{account}", s)
    return s.replace("arn:", "")


def mask_session_name(name: str) -> str:
    """Identity Center session name (the user name, often an e-mail address) -> its local part."""
    local = (name or "").split("@", 1)[0]
    return mask_text(local)[:64] or "(unnamed)"


def mask_ip(value: str) -> str:
    """203.0.113.10 -> 203.0.113.x; IPv6 -> first three groups; an AWS service name stays (masked as text)."""
    if not value:
        return "(none)"
    try:
        ip = ipaddress.ip_address(value)
    except ValueError:
        return mask_text(value)[:64]
    if ip.version == 4:
        return ".".join(str(ip).split(".")[:3]) + ".x"
    return ":".join(ip.exploded.split(":")[:3]) + ":…"


# ── Parsing ─────────────────────────────────────────────────────────────────────────────────────────────────────────

def parse_time(value) -> datetime | None:
    if value is None or value == "":
        return None
    if isinstance(value, datetime):
        return value if value.tzinfo else value.replace(tzinfo=timezone.utc)
    s = str(value).strip()
    try:
        dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
        return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)
    except ValueError:
        pass
    for fmt in _STS_EXPIRATION_FORMATS:  # CloudTrail writes STS expirations as "Oct 31, 2026, 3:00:12 AM" (UTC)
        try:
            return datetime.strptime(s, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    return None


def permission_set_of(role_arn_or_name: str, admin_sets) -> str | None:
    name = (role_arn_or_name or "").rsplit("/", 1)[-1]
    m = _ROLE_RE.search(name)
    if not m or m.group("set") not in admin_sets:
        return None
    return m.group("set")


def _ct(raw: dict) -> dict:
    """The CloudTrailEvent JSON of one LookupEvents row."""
    body = raw.get("CloudTrailEvent")
    if isinstance(body, dict):
        return body
    try:
        return json.loads(body or "{}")
    except ValueError:
        return {}


@dataclass
class Session:
    event_id: str
    session_name: str  # raw: used for the lookup only, never logged or mailed unmasked
    role_name: str
    permission_set: str
    start: datetime
    expires: datetime
    access_key: str
    source_ip: str
    region: str

    @property
    def group(self) -> tuple[str, str]:
        return (self.session_name, self.role_name)


def session_from_saml(raw: dict, admin_sets) -> Session | None:
    """One AssumeRoleWithSAML LookupEvents row -> a Session, or None (not an admin set, failed call, bad shape)."""
    ct = _ct(raw)
    if ct.get("eventName", raw.get("EventName")) != "AssumeRoleWithSAML" or ct.get("errorCode"):
        return None
    req = ct.get("requestParameters") or {}
    role_arn = req.get("roleArn") or ""
    ps = permission_set_of(role_arn, admin_sets)
    start = parse_time(ct.get("eventTime")) or parse_time(raw.get("EventTime"))
    name = req.get("roleSessionName") or ""
    if not ps or not start or not name:
        return None
    creds = (ct.get("responseElements") or {}).get("credentials") or {}
    expires = parse_time(creds.get("expiration"))
    if expires is None:
        try:
            expires = start + timedelta(seconds=int(req.get("durationSeconds")))
        except (TypeError, ValueError):
            expires = start + MAX_SESSION
    return Session(
        event_id=ct.get("eventID") or raw.get("EventId") or "",
        session_name=name,
        role_name=role_arn.rsplit("/", 1)[-1],
        permission_set=ps,
        start=start,
        expires=min(expires, start + MAX_SESSION),
        access_key=creds.get("accessKeyId") or "",
        source_ip=ct.get("sourceIPAddress") or "",
        region=ct.get("awsRegion") or "",
    )


@dataclass
class Activity:
    event_id: str
    time: datetime
    service: str
    event_name: str
    read_only: bool
    error_code: str
    resources: list[str]
    region: str
    source_ip: str
    console: bool
    access_key: str
    role_name: str
    identity_type: str
    created: datetime | None = None

    @property
    def is_delete(self) -> bool:
        return not self.read_only and self.event_name.startswith(_DELETE_VERBS)


def _read_only(ct: dict, raw: dict, event_name: str) -> bool:
    flag = ct.get("readOnly", raw.get("ReadOnly"))
    if isinstance(flag, bool):
        return flag
    if isinstance(flag, str) and flag.lower() in ("true", "false"):
        return flag.lower() == "true"
    return event_name.startswith(_READ_VERBS)


def _resource_names(ct: dict, raw: dict) -> list[str]:
    names: list[str] = []
    for r in raw.get("Resources") or []:
        n = r.get("ResourceName") or ""
        if n:
            names.append(arn_resource_name(n) if n.startswith("arn:") else n)
    if not names:
        req = ct.get("requestParameters") or {}
        if isinstance(req, dict):
            for k in _NAME_KEYS:
                v = req.get(k)
                if isinstance(v, str) and v:
                    names.append(arn_resource_name(v) if v.startswith("arn:") else v)
                if len(names) >= 3:
                    break
    out: list[str] = []
    for n in names:
        m = mask_text(n)[:120]
        if m and m not in out:
            out.append(m)
    return out[:3]


def activity_from_lookup(raw: dict) -> Activity | None:
    ct = _ct(raw)
    when = parse_time(ct.get("eventTime")) or parse_time(raw.get("EventTime"))
    name = ct.get("eventName") or raw.get("EventName") or ""
    if not when or not name:
        return None
    ident = ct.get("userIdentity") or {}
    issuer = ((ident.get("sessionContext") or {}).get("sessionIssuer") or {})
    attrs = (ident.get("sessionContext") or {}).get("attributes") or {}
    source = ct.get("eventSource") or raw.get("EventSource") or ""
    return Activity(
        event_id=ct.get("eventID") or raw.get("EventId") or "",
        time=when,
        service=source.split(".", 1)[0] or "?",
        event_name=name,
        read_only=_read_only(ct, raw, name),
        error_code=ct.get("errorCode") or "",
        resources=_resource_names(ct, raw),
        region=ct.get("awsRegion") or "",
        source_ip=ct.get("sourceIPAddress") or "",
        console=str(ct.get("sessionCredentialFromConsole", "")).lower() == "true",
        access_key=ident.get("accessKeyId") or raw.get("AccessKeyId") or "",
        role_name=issuer.get("userName") or "",
        identity_type=ident.get("type") or "",
        created=parse_time(attrs.get("creationDate")),
    )


# ── Attribution and session end ─────────────────────────────────────────────────────────────────────────────────────

def belongs_to_group(act: Activity, role_name: str, keys) -> bool:
    if act.event_name == "AssumeRoleWithSAML":
        return False
    if act.access_key and act.access_key in keys:
        return True
    return act.identity_type == "AssumedRole" and act.role_name == role_name


def attribute(acts: list[Activity], sessions: list[Session]) -> dict[str, list[Activity]]:
    """Each event of one (user, role) group -> exactly one session of that group (see the module docstring)."""
    out: dict[str, list[Activity]] = {s.event_id: [] for s in sessions}
    by_key = {s.access_key: s for s in sessions if s.access_key}
    ordered = sorted(sessions, key=lambda s: s.start)
    for a in acts:
        target = by_key.get(a.access_key)
        if target is None and a.created is not None:
            near = [s for s in ordered if abs((s.start - a.created).total_seconds()) <= 300]
            if near:
                target = min(near, key=lambda s: abs((s.start - a.created).total_seconds()))
        if target is None:
            live = [s for s in ordered if s.start - timedelta(minutes=1) <= a.time <= s.expires + timedelta(minutes=5)]
            if live:
                target = live[-1]
        if target is not None:
            out[target.event_id].append(a)
    for v in out.values():
        v.sort(key=lambda a: (a.time, a.event_id))
    return out


def session_end(s: Session, acts: list[Activity], *, now: datetime, idle: timedelta, lag: timedelta,
                after: datetime | None = None) -> tuple[bool, datetime, str]:
    """(over, end time, reason). `after` = the previous digest's reported_through (a continued session)."""
    last = max([a.time for a in acts] + [after or s.start, s.start])
    if now >= s.expires + lag:
        return True, s.expires, "credentials expired"
    if now - last >= idle:
        return True, last, f"no activity for {int(idle.total_seconds() // 60)} min"
    return False, last, "still active"


# ── Digest text ─────────────────────────────────────────────────────────────────────────────────────────────────────

def _fmt(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ")


def _fmt_both(dt: datetime) -> str:
    return f"{dt.astimezone(timezone.utc):%Y-%m-%d %H:%M}Z ({dt.astimezone(ICT):%H:%M} ICT)"


def _write_line(a: Activity) -> str:
    res = ", ".join(a.resources) if a.resources else "-"
    err = f"  error: {mask_text(a.error_code)}" if a.error_code else ""
    where = f" [{a.region}]" if a.region else ""
    return f"  {_fmt(a.time)}  {a.service}:{a.event_name}  {res}{where}{err}"


def build_digest(s: Session, acts: list[Activity], *, end: datetime, reason: str, env_name: str, regions,
                 truncated: bool = False, continued_from: datetime | None = None, runbook_url: str = "",
                 preview: bool = False) -> tuple[str, str]:
    """(subject, message). Every line passes through mask_text()."""
    who = mask_session_name(s.session_name)
    ps = mask_text(s.permission_set)
    deletes = [a for a in acts if a.is_delete]
    writes = [a for a in acts if not a.read_only and not a.is_delete]
    reads = [a for a in acts if a.read_only]
    errors = sum(1 for a in acts if a.error_code)

    tag = "admin session digest" + (" (continued)" if continued_from else "") + (" [preview]" if preview else "")
    subject = f"[aa-sec] {tag}: {who} ({ps}) {s.start.astimezone(timezone.utc):%Y-%m-%d %H:%MZ}"
    subject = mask_text(subject).encode("ascii", "replace").decode("ascii")[:SUBJECT_MAX]

    lines = [
        f"[aa-sec] sso_admin_session_digest ({env_name}): what the Identity Center session '{who}' on the {ps} "
        f"permission set did.",
        "",
        f"Session start: {_fmt_both(s.start)} from {mask_ip(s.source_ip)}",
        f"Session end:   {_fmt_both(end)} ({reason}); credentials valid until {_fmt_both(s.expires)}",
    ]
    if continued_from:
        lines.append(f"Continued: events after the previous digest ({_fmt_both(continued_from)}) only.")
    ips = Counter(mask_ip(a.source_ip) for a in acts if a.source_ip)
    if ips:
        lines.append("Source IPs: " + ", ".join(f"{ip} ({n})" for ip, n in ips.most_common(8)))
    console = sum(1 for a in acts if a.console)
    lines.append(f"Calls: {len(acts)} ({len(deletes)} delete, {len(writes)} other write, {len(reads)} read-only, "
                 f"{errors} with an error code; console {console}, API {len(acts) - console}). "
                 f"Regions looked up: {', '.join(regions)}.")
    if truncated:
        lines.append("WARNING: the lookup hit its page cap; the counts below are a lower bound. "
                     "Read the rest in CloudTrail Event history.")
    if not acts:
        lines.append("No call by this session was found in CloudTrail.")

    if acts:
        lines += ["", "Per service (calls / writes / errors):"]
        per = defaultdict(lambda: [0, 0, 0])
        for a in acts:
            p = per[a.service]
            p[0] += 1
            p[1] += 0 if a.read_only else 1
            p[2] += 1 if a.error_code else 0
        for svc, (n, w, e) in sorted(per.items(), key=lambda kv: (-kv[1][1], -kv[1][0], kv[0])):
            lines.append(f"  {svc:<22} {n:>5} / {w:>4} / {e:>4}")

    listed = 0
    for title, group in (("DELETE actions", deletes), ("Other WRITE actions", writes)):
        if not group:
            continue
        lines += ["", f"{title} ({len(group)}), oldest first:"]
        for a in group:
            if listed >= WRITE_LINES_MAX:
                break
            lines.append(_write_line(a))
            listed += 1
    hidden = len(deletes) + len(writes) - listed
    if hidden > 0:
        lines.append(f"  ... and {hidden} more write/delete calls (CloudTrail Event history has them).")

    if reads:
        counts = Counter((a.service, a.event_name) for a in reads)
        lines += ["", f"Read-only calls ({len(reads)}), by count:"]
        for (svc, ev), n in counts.most_common(READ_LINES_MAX):
            lines.append(f"  {n:>5}  {svc}:{ev}")
        if len(counts) > READ_LINES_MAX:
            lines.append(f"  ... and {len(counts) - READ_LINES_MAX} more kinds of read-only call.")

    lines += ["", "Expected only for a session the tech lead started; otherwise treat it as an incident "
                  "(AA-873, AA-1022)." + (f" Runbook: {runbook_url}" if runbook_url else "")]
    message = "\n".join(mask_text(line) for line in lines)
    return subject, message


# ── AWS calls ───────────────────────────────────────────────────────────────────────────────────────────────────────

def lookup(client, attribute_key: str, value: str, start: datetime, end: datetime, max_pages: int):
    """(rows, truncated). LookupEvents is paged 50 rows at a time, at most 2 calls/s per region (retries in the
    client config)."""
    rows: list[dict] = []
    kwargs = {"LookupAttributes": [{"AttributeKey": attribute_key, "AttributeValue": value}],
              "StartTime": start, "EndTime": end, "MaxResults": 50}
    for _ in range(max_pages):
        resp = client.lookup_events(**kwargs)
        rows.extend(resp.get("Events") or [])
        token = resp.get("NextToken")
        if not token:
            return rows, False
        kwargs["NextToken"] = token
    return rows, True


def find_sessions(clients: dict, regions, admin_sets, start: datetime, end: datetime, max_pages: int) -> list[Session]:
    found: dict[str, Session] = {}
    for region in regions:
        rows, _ = lookup(clients[region], "EventName", "AssumeRoleWithSAML", start, end, max_pages)
        for raw in rows:
            s = session_from_saml(raw, admin_sets)
            if s and s.event_id and s.event_id not in found:
                found[s.event_id] = s
    return sorted(found.values(), key=lambda s: s.start)


def group_activity(clients: dict, regions, sessions: list[Session], start: datetime, end: datetime,
                   max_pages: int) -> tuple[list[Activity], bool]:
    """Every call of one (user, role) group in [start, end], across the activity regions, deduplicated."""
    name, role = sessions[0].group
    keys = {s.access_key for s in sessions if s.access_key}
    acts: dict[str, Activity] = {}
    truncated = False

    def add(rows):
        for raw in rows:
            a = activity_from_lookup(raw)
            if a and a.event_id not in acts and belongs_to_group(a, role, keys):
                acts[a.event_id] = a

    for region in regions:
        rows, cut = lookup(clients[region], "Username", name, start, end, max_pages)
        truncated |= cut
        add(rows)
    seen_keys = {a.access_key for a in acts.values()}
    for key in sorted(keys - seen_keys):
        for region in regions:
            rows, cut = lookup(clients[region], "AccessKeyId", key, start, end, max_pages)
            truncated |= cut
            add(rows)
    return sorted(acts.values(), key=lambda a: (a.time, a.event_id)), truncated


class StateStore:
    """The reported-sessions object in S3 (missing object = empty state)."""

    def __init__(self, s3, bucket: str, key: str):
        self.s3, self.bucket, self.key = s3, bucket, key

    def load(self) -> dict:
        try:
            body = self.s3.get_object(Bucket=self.bucket, Key=self.key)["Body"].read()
        except Exception as exc:  # noqa: BLE001 — botocore ClientError; tests use no boto3
            code = (getattr(exc, "response", None) or {}).get("Error", {}).get("Code")
            if code in ("NoSuchKey", "404"):
                return {"version": STATE_VERSION, "sessions": {}}
            raise
        data = json.loads(body or b"{}")
        if not isinstance(data.get("sessions"), dict):
            raise ValueError("state object has no sessions map")
        return data

    def save(self, state: dict) -> None:
        self.s3.put_object(Bucket=self.bucket, Key=self.key, ContentType="application/json",
                           Body=json.dumps(state, sort_keys=True, separators=(",", ":")).encode())


def prune(state: dict, now: datetime, keep: timedelta) -> int:
    old = [k for k, v in state["sessions"].items() if (parse_time(v.get("expires")) or now) < now - keep]
    for k in old:
        del state["sessions"][k]
    return len(old)


# ── Run ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

def _log(obj: dict) -> None:
    print(json.dumps(obj, default=str, sort_keys=True, ensure_ascii=False))


def _int_env(env: dict, name: str, default: int, minimum: int) -> int:
    raw = env.get(name, str(default))
    try:
        value = int(raw)
    except ValueError as exc:
        raise ValueError(f"{name} must be an integer, got {raw!r}") from exc
    if value < minimum:
        raise ValueError(f"{name} must be >= {minimum}, got {value}")
    return value


def _list_env(env: dict, name: str) -> list[str]:
    out = [x.strip() for x in (env.get(name) or "").split(",") if x.strip()]
    if not out:
        raise ValueError(f"{name} is empty")
    return out


def run(clients: dict, sns, s3, *, env: dict, now: datetime, event: dict | None = None,
        time_left=lambda: 10 ** 9) -> dict:
    event = event or {}
    preview = event.get("preview") is True
    admin_sets = set(_list_env(env, "ADMIN_PERMISSION_SETS"))
    saml_regions = _list_env(env, "SAML_REGIONS")
    act_regions = _list_env(env, "ACTIVITY_REGIONS")
    lookback = timedelta(hours=_int_env(env, "LOOKBACK_HOURS", 36, 13))
    idle = timedelta(minutes=_int_env(env, "IDLE_MINUTES", 60, 15))
    lag = timedelta(minutes=_int_env(env, "DELIVERY_LAG_MINUTES", 15, 0))
    max_pages = _int_env(env, "MAX_PAGES", 100, 1)
    env_name = env.get("ENV_NAME", "dev")
    runbook = env.get("RUNBOOK_URL", "")
    topic = env.get("ALERT_TOPIC_ARN", "")
    missing = sorted(set(saml_regions + act_regions) - set(clients))
    if missing:
        raise ValueError(f"no CloudTrail client for {missing}")

    if preview:
        since, until = parse_time(event.get("since")), parse_time(event.get("until"))
        until = min(until, now) if until else None
        if not since or not until or since >= until:
            raise ValueError("preview needs 'since' < 'until' (ISO 8601), 'since' in the past")
        store, state = None, {"version": STATE_VERSION, "sessions": {}}
    else:
        since, until = now - lookback, now
        if not topic:
            raise ValueError("ALERT_TOPIC_ARN is empty")
        store = StateStore(s3, env.get("STATE_BUCKET", ""), env.get("STATE_KEY", ""))
        if not store.bucket or not store.key:
            raise ValueError("STATE_BUCKET / STATE_KEY are empty")
        state = store.load()

    sessions = find_sessions(clients, saml_regions, admin_sets, since, until, max_pages)
    summary = {"event": "summary", "preview": preview, "since": _fmt(since), "until": _fmt(until),
               "sessions_found": len(sessions), "digests": 0, "waiting": 0, "closed_quietly": 0,
               "deferred": 0, "messages": [] if preview else None}
    groups: dict[tuple[str, str], list[Session]] = defaultdict(list)
    for s in sessions:
        groups[s.group].append(s)

    for members in groups.values():
        seen = state["sessions"]
        todo = [s for s in members if not (seen.get(s.event_id) or {}).get("closed")]
        if not todo:
            continue
        if time_left() < 90_000:  # leave the rest for the next hourly run (state not written for them)
            summary["deferred"] += len(todo)
            continue
        fetch_from = min(parse_time((seen.get(s.event_id) or {}).get("reported_through")) or s.start for s in todo)
        fetch_from -= timedelta(minutes=1)
        fetch_to = min(now, max(s.expires for s in todo) + lag)
        acts, truncated = ([], False) if fetch_from >= fetch_to else group_activity(
            clients, act_regions, members, fetch_from, fetch_to, max_pages)
        per = attribute(acts, members)
        for s in todo:
            prev = seen.get(s.event_id)
            after = parse_time(prev.get("reported_through")) if prev else None
            mine = [a for a in per[s.event_id] if after is None or a.time > after]
            over, end, reason = session_end(s, per[s.event_id], now=now, idle=idle, lag=lag, after=after)
            expired = now >= s.expires + lag
            if not over and not preview:
                summary["waiting"] += 1
                continue
            if prev and not mine:
                if expired:
                    prev["closed"] = True
                    summary["closed_quietly"] += 1
                    store.save(state)
                continue
            subject, message = build_digest(
                s, mine, end=end, reason=reason if over else "still open at preview time", env_name=env_name,
                regions=act_regions, truncated=truncated, continued_from=after, runbook_url=runbook, preview=preview)
            _log({"event": "digest", "session": s.event_id, "subject": subject, "message": message,
                  "calls": len(mine), "truncated": truncated, "preview": preview})
            summary["digests"] += 1
            if preview:
                summary["messages"].append({"subject": subject, "message": message})
                continue
            sns.publish(TopicArn=topic, Subject=subject, Message=message)
            seen[s.event_id] = {
                "start": _fmt(s.start), "expires": _fmt(s.expires),
                "reported_through": _fmt(max([a.time for a in mine] + [after or s.start, end])),
                "closed": expired, "digests": int((prev or {}).get("digests", 0)) + 1,
            }
            store.save(state)  # after each mail, so a later failure never re-sends this one

    if store is not None and prune(state, now, lookback + timedelta(days=1)):
        store.save(state)
    if summary["messages"] is None:
        del summary["messages"]
    _log({k: v for k, v in summary.items() if k != "messages"})
    return summary


def handler(event, context):
    import boto3  # bundled with the Lambda runtime; imported here so tests need no boto3
    from botocore.config import Config

    env = dict(os.environ)
    cfg = Config(retries={"mode": "adaptive", "max_attempts": 10})
    regions = set(_list_env(env, "SAML_REGIONS")) | set(_list_env(env, "ACTIVITY_REGIONS"))
    clients = {r: boto3.client("cloudtrail", region_name=r, config=cfg) for r in sorted(regions)}
    return run(clients, boto3.client("sns"), boto3.client("s3"), env=env, now=datetime.now(timezone.utc),
               event=event if isinstance(event, dict) else {},
               time_left=getattr(context, "get_remaining_time_in_millis", lambda: 10 ** 9))
