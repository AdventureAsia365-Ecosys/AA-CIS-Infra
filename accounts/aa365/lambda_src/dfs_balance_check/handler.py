"""AA-627 — daily DataForSEO balance-check trigger.

EventBridge Scheduler (once/day) -> this Lambda -> POST /admin/dfs-balance/check with the
X-Admin-Secret header. The backend reads the FREE DFS balance, stores a snapshot, and raises a
low-balance notification if it is below the threshold. This Lambda is a thin trigger only: it
holds no DataForSEO credentials (the ECS backend has those) and no DB access.

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


def handler(event, context):
    url = f"{_API}/admin/dfs-balance/check"
    req = urllib.request.Request(
        url,
        data=b"{}",
        headers={"Content-Type": "application/json", "X-Admin-Secret": _SECRET},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read().decode()
            logger.info("dfs_balance_check ok: %s", body[:300])
            return {"statusCode": 200, "body": body}
    except urllib.error.HTTPError as exc:
        err = exc.read().decode()[:300]
        logger.error("dfs_balance_check http_error=%s body=%s", exc.code, err)
        # Re-raise so the Scheduler retry policy kicks in on a real backend failure.
        raise
    except Exception as exc:
        logger.error("dfs_balance_check exception: %s", exc)
        raise
