#!/usr/bin/env python3
"""Live checks of the AA-Partner edge: CloudFront -> VPC origin -> NLB -> ALB (AA-931, AA-933, AA-935). Stdlib only, no
AWS calls.

Run after an apply that touches crm_edge.tf, crm_app.tf, crm_web.tf or alb_rules.tf. No task needs to run: with the web
at desired 0 the partner host's default rule answers the ALB's 503, which still proves the path, so the edge is checked
at $0.
  python3 tools/terraform/crm_edge_live_check.py --cf-domain <distribution>.cloudfront.net

Checks (exit 1 if any fails):
  partner-root   https://<partner host>/        the CRM web (crm_partner_default -> aa-crm-dev-web): 307 to
                                                /auth/refresh (no session), or 503 = the rule matched but the web has
                                                no healthy task (desired 0): reported, not failed. Never the old fixed
                                                404 JSON, never the API (proves CloudFront -> VPC origin -> NLB -> ALB
                                                host + secret rule)
  partner-path   https://<partner host>/crmx    the same: /crmx is not /crm or /crm/*, so the web, not the API
  web-healthz    https://<partner host>/healthz 200 {"service": "aa-crm-web"} or 503 (no healthy web task)
  crm-health     https://<partner host>/crm/health   200 = the API answers (crm_api rule); 503 = the rule matched but
                                                aa-crm-dev-api has no healthy task (desired 0): reported, not failed
  raw-cf         https://<cf domain>/           403 "Forbidden" from the ALB deny rule (never CIS / Booking)
  api-header     https://<api host>/health + X-AA-Origin: guess   403 (deny rule) or 200 (header dropped),
                                                never the partner 404
  api-plain      https://<api host>/health      200 (CIS unchanged)
  booking        https://<booking host>/booking/health   200 (Booking unchanged)
"""
from __future__ import annotations

import argparse
import http.client
import json
import sys
from typing import Callable

GUESS_HEADER = {"X-AA-Origin": "aa931-live-check-guess"}  # deliberately wrong: must be refused
# The partner host's fixed default before AA-935 (crm_edge.tf). Seeing it again means the web rule was lost.
PARTNER_404 = {"detail": "Not Found"}

Result = tuple[bool, str]


def get(host: str, path: str, headers: dict | None = None, timeout: float = 30.0) -> tuple[int, bytes, str, str]:
    """(status, body, Content-Type, Location). Redirects are not followed."""
    conn = http.client.HTTPSConnection(host, timeout=timeout)
    try:
        conn.request("GET", path, headers={"User-Agent": "aa935-edge-live-check", **(headers or {})})
        resp = conn.getresponse()
        return resp.status, resp.read(), resp.getheader("Content-Type", "") or "", resp.getheader("Location", "") or ""
    finally:
        conn.close()


def _json(body: bytes):
    try:
        return json.loads(body)
    except ValueError:
        return None


def is_partner_404(status: int, body: bytes, ctype: str) -> bool:
    return status == 404 and ctype.split(";")[0].strip() == "application/json" and _json(body) == PARTNER_404


def eval_web_default(status: int, body: bytes, ctype: str, location: str = "") -> Result:
    """The partner host's default rule reaches the CRM web: a page without a session goes to /auth/refresh."""
    if status == 307 and "/auth/refresh" in location:
        return True, f"status=307 -> {location} (AA-Partner web answers)"
    if status == 503 and not is_partner_404(status, body, ctype) and _json(body) is None:
        return True, "status=503 (rule matched, aa-crm-dev-web has no healthy task: desired 0?)"
    return False, f"status={status} type={ctype or '-'} location={location or '-'} body={body[:60]!r}"


def eval_web_healthz(status: int, body: bytes, ctype: str, location: str = "") -> Result:
    data = _json(body)
    if status == 200 and isinstance(data, dict) and data.get("service") == "aa-crm-web":
        return True, f"status=200 git_sha={data.get('git_sha')} auth_configured={data.get('auth_configured')}"
    if status == 503 and data is None:
        return True, "status=503 (no healthy web task: desired 0?)"
    return False, f"status={status} body={body[:60]!r}"


def eval_crm_health(status: int, body: bytes, ctype: str, location: str = "") -> Result:
    if status == 200:
        return True, "status=200 (AA-Partner API answers)"
    if status == 503 and not is_partner_404(status, body, ctype):
        return True, "status=503 (rule matched, aa-crm-dev-api has no healthy task: desired 0?)"
    return False, f"status={status} body={body[:60]!r}"


def eval_raw_cf(status: int, body: bytes, ctype: str, location: str = "") -> Result:
    return status == 403 and body.strip() == b"Forbidden", f"status={status} body={body[:40]!r}"


def eval_api_header(status: int, body: bytes, ctype: str, location: str = "") -> Result:
    # 403 = API Gateway forwarded the header and the ALB deny rule caught it; 200 = API Gateway dropped it (also safe).
    return status in (200, 403) and not is_partner_404(status, body, ctype), f"status={status}"


def eval_ok(status: int, body: bytes, ctype: str, location: str = "") -> Result:
    return status == 200, f"status={status}"


def build_checks(args: argparse.Namespace) -> dict[str, Callable[[], Result]]:
    def run(evaluate, host, path, headers=None):
        return lambda: evaluate(*get(host, path, headers))

    return {
        "partner-root": run(eval_web_default, args.host, "/"),
        "partner-path": run(eval_web_default, args.host, "/crmx"),
        "web-healthz": run(eval_web_healthz, args.host, "/healthz"),
        "crm-health": run(eval_crm_health, args.host, "/crm/health"),
        "raw-cf": run(eval_raw_cf, args.cf_domain, "/"),
        "api-header": run(eval_api_header, args.api_host, "/health", GUESS_HEADER),
        "api-plain": run(eval_ok, args.api_host, "/health"),
        "booking": run(eval_ok, args.booking_host, "/booking/health"),
    }


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="AA-Partner CloudFront edge live checks (AA-931, AA-933, AA-935)")
    ap.add_argument("--host", default="partner-dev.lumiguides.it.com")
    ap.add_argument("--cf-domain", required=True, help="the distribution's *.cloudfront.net name (terraform output crm_edge)")
    ap.add_argument("--api-host", default="api-cis.lumiguides.it.com")
    ap.add_argument("--booking-host", default="api-booking.lumiguides.it.com")
    ap.add_argument("--only", default="", help="comma list of check names")
    args = ap.parse_args(argv)
    only = {c for c in args.only.split(",") if c}

    failed = 0
    for name, fn in build_checks(args).items():
        if only and name not in only:
            continue
        try:
            ok, detail = fn()
        except Exception as exc:  # noqa: BLE001 - report and continue
            ok, detail = False, f"error {type(exc).__name__}: {exc}"
        failed += 0 if ok else 1
        print(f"{'PASS' if ok else 'FAIL'}  {name:<12} {detail}", flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
