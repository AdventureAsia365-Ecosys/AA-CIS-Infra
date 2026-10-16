"""AA-627 + AA-720 + AA-825 — ops-probe trigger.

EventBridge Scheduler -> this Lambda -> a short list of secret-gated admin POSTs. Each backend
endpoint does its own work (read a balance, probe a vendor, sweep a log, enqueue jobs) and raises its
own throttled bell; this Lambda is a thin trigger only — no vendor credentials, no DB.

Paths called by the 06:15 UTC probe schedule (the default when the event names no paths; order
matters only for logging; each is independent — one failing path does NOT stop the others, and a
non-2xx is logged, not raised, so one flaky endpoint can't suppress the rest or spam retries):
  AA-627  POST /admin/dfs-balance/check — read FREE DFS balance, snapshot, low-balance bell.
  AA-720  POST /admin/jev-canary/check  — one real Jev decide-endpoint probe; 402 -> credit bell
          + breaker trip, even on a zero-traffic day.
  AA-720  POST /admin/jev/402-sweep     — count decision_log 402s in the last 24h; bell if any.
  AA-727  POST /admin/waves/check       — evaluate open rerun waves; one bell when a wave's jobs
          finished but some expected tour is not in a terminal state.

Called by their own schedules (the event names the path):
  AA-825  POST /admin/job-runner/retention/schedule — enqueue one job per CIS retention kind,
          idempotent per UTC day (shared.job idempotency_key retention:<kind>:<day>); each kind
          decides itself whether it runs as a DRY RUN, live or held. Nothing is enqueued while a
          rerun wave is open.
  (AA-832's every-5-minutes /admin/job-runner/rds-role-connections/schedule path was removed in
  AA-751: the CIS api publishes those metrics from an in-process sampler.)

Event (the Scheduler target input; every key optional):
  {"paths": ["/admin/..."], "secret_id": "<Secrets Manager ARN or name>"}
  - paths: which admin paths to POST. Only paths in _ALLOWED_PATHS are called; any other is logged
    and skipped, so an invoke can never aim the admin secret at an arbitrary route.
  - secret_id: read the X-Admin-Secret value from Secrets Manager at run time (a rotated secret is
    picked up without a redeploy). If the read fails, the deploy-time env value is used instead.

Kept as ONE Lambda (not one per concern): all of these are the same "in-VPC, admin-secret POST"
shape, so adding a path (or a schedule that names one) is cheaper than a new function + role. The
function name stays dfs-balance-check (renaming the IAM role would destroy+recreate it, a brief
permission gap — S200).

Env:
  API_BASE_URL  — e.g. https://api-cis.lumiguides.it.com (no trailing slash needed)
  ADMIN_SECRET  — the X-Admin-Secret value injected at deploy time (fallback when no secret_id or
                  the run-time read fails)
"""
import json
import logging
import os
import urllib.error
import urllib.request

logger = logging.getLogger()
logger.setLevel(logging.INFO)

_API = os.environ["API_BASE_URL"].rstrip("/")
_ENV_SECRET = os.environ.get("ADMIN_SECRET", "")

# The default run (06:15 UTC probe schedule, no "paths" in the event). Independent: a failure in one
# is logged and the rest still run.
_PATHS = (
    "/admin/dfs-balance/check",   # AA-627
    "/admin/jev-canary/check",    # AA-720
    "/admin/jev/402-sweep",       # AA-720
    "/admin/waves/check",         # AA-727
)

# Paths a schedule may name in its event. Anything else is refused.
RETENTION_SCHEDULE_PATH = "/admin/job-runner/retention/schedule"   # AA-825
_ALLOWED_PATHS = frozenset(_PATHS + (RETENTION_SCHEDULE_PATH,))


def _read_secret(secret_id):
    """Read the admin secret at run time. Returns None on any failure (the caller falls back to the
    deploy-time env value). boto3 ships with the Lambda Python runtime; imported lazily so the
    module still loads where it is absent."""
    try:
        import boto3
        resp = boto3.client("secretsmanager").get_secret_value(SecretId=secret_id)
        value = resp.get("SecretString") or ""
        return value.strip() or None
    except Exception as exc:                       # permissions / network / missing secret
        logger.error("ops_probe secret_read_failed error=%s", type(exc).__name__)
        return None


def _resolve_secret(event):
    secret_id = event.get("secret_id")
    if secret_id:
        value = _read_secret(secret_id)
        if value:
            return value, "secrets_manager"
    return _ENV_SECRET, "env"


def _select_paths(event):
    """The paths this run POSTs: the event's list filtered to _ALLOWED_PATHS (order kept, duplicates
    dropped), or _PATHS when the event names none."""
    requested = event.get("paths")
    if not requested:
        return _PATHS
    if isinstance(requested, str):
        requested = [requested]
    out = []
    for path in requested:
        if path not in _ALLOWED_PATHS:
            logger.error("ops_probe path_refused path=%s", path)
        elif path not in out:
            out.append(path)
    return tuple(out)


def _post(path, secret):
    """POST one admin path. Returns (ok, status, body_snippet). Never raises — a single flaky
    endpoint must not stop the other daily probes or trigger Scheduler retries for the whole run."""
    url = f"{_API}{path}"
    req = urllib.request.Request(
        url,
        data=b"{}",
        headers={"Content-Type": "application/json", "X-Admin-Secret": secret},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read().decode()[:300]
            logger.info("ops_probe ok path=%s body=%s", path, body)
            return True, resp.status, body
    except urllib.error.HTTPError as exc:
        body = exc.read().decode()[:300]
        logger.error("ops_probe http_error path=%s status=%s body=%s", path, exc.code, body)
        return False, exc.code, body
    except Exception as exc:                       # timeout / DNS / connection
        logger.error("ops_probe exception path=%s error=%s", path, exc)
        return False, None, str(exc)[:300]


def handler(event, context):
    event = event if isinstance(event, dict) else {}
    paths = _select_paths(event)
    secret, source = _resolve_secret(event)
    logger.info("ops_probe run paths=%s secret_source=%s", list(paths), source)
    results = {}
    any_ok = False
    for path in paths:
        ok, status, body = _post(path, secret)
        results[path] = {"ok": ok, "status": status}
        any_ok = any_ok or ok
    # 200 as long as at least one probe reached the backend; the per-path status is in the body.
    # Each endpoint already surfaces its own problem via a throttled bell, so we do not raise here
    # (raising would retry ALL paths, including ones that succeeded).
    status_code = 200 if any_ok else 502
    return {"statusCode": status_code, "body": json.dumps(results)}
