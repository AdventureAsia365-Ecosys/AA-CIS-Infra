"""AA-627 + AA-720 — daily ops-probe trigger.

EventBridge Scheduler (once/day) -> this Lambda -> a short list of secret-gated admin POSTs. Each
backend endpoint does its own work (read a balance, probe a vendor, sweep a log) and raises its own
throttled bell; this Lambda is a thin trigger only — no vendor credentials, no DB.

Paths called each run (order matters only for logging; each is independent — one failing path does
NOT stop the others, and a non-2xx is logged, not raised, so one flaky endpoint can't suppress the
rest or spam Scheduler retries):
  AA-627  POST /admin/dfs-balance/check — read FREE DFS balance, snapshot, low-balance bell.
  AA-720  POST /admin/jev-canary/check  — one real Jev decide-endpoint probe; 402 -> credit bell
          + breaker trip, even on a zero-traffic day.
  AA-720  POST /admin/jev/402-sweep     — count decision_log 402s in the last 24h; bell if any.
  AA-727  POST /admin/waves/check       — evaluate open rerun waves; one bell when a wave's jobs
          finished but some expected tour is not in a terminal state.

Kept as ONE Lambda (not one per concern): all three are the same "once-a-day, in-VPC, admin-secret
POST" shape, so adding a path is cheaper than a new function + role + schedule. The function name
stays dfs-balance-check (renaming the IAM role would destroy+recreate it, a brief permission gap —
S200). History: AA-627 shipped the DFS path; AA-720 added the two Jev paths.

Env:
  API_BASE_URL  — e.g. https://api-cis.lumiguides.it.com (no trailing slash needed)
  ADMIN_SECRET  — the X-Admin-Secret value (injected from Secrets Manager at deploy time)
"""
import json
import logging
import os
import urllib.error
import urllib.request

logger = logging.getLogger()
logger.setLevel(logging.INFO)

_API = os.environ["API_BASE_URL"].rstrip("/")
_SECRET = os.environ.get("ADMIN_SECRET", "")

# Each run POSTs these in order. Independent: a failure in one is logged and the rest still run.
_PATHS = (
    "/admin/dfs-balance/check",   # AA-627
    "/admin/jev-canary/check",    # AA-720
    "/admin/jev/402-sweep",       # AA-720
    "/admin/waves/check",         # AA-727
)


def _post(path):
    """POST one admin path. Returns (ok, status, body_snippet). Never raises — a single flaky
    endpoint must not stop the other daily probes or trigger Scheduler retries for the whole run."""
    url = f"{_API}{path}"
    req = urllib.request.Request(
        url,
        data=b"{}",
        headers={"Content-Type": "application/json", "X-Admin-Secret": _SECRET},
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
    results = {}
    any_ok = False
    for path in _PATHS:
        ok, status, body = _post(path)
        results[path] = {"ok": ok, "status": status}
        any_ok = any_ok or ok
    # 200 as long as at least one probe reached the backend; the per-path status is in the body.
    # Each endpoint already surfaces its own problem via a throttled bell, so we do not raise here
    # (raising would retry ALL paths, including ones that succeeded).
    status_code = 200 if any_ok else 502
    return {"statusCode": status_code, "body": json.dumps(results)}
