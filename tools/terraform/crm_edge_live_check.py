#!/usr/bin/env python3
"""Live checks of the AA-Partner edge: CloudFront -> VPC origin -> NLB -> ALB (AA-931, AA-933, AA-935, AA-936). Stdlib only, no
AWS calls.

Run after an apply that touches crm_edge.tf, crm_app.tf, crm_web.tf or alb_rules.tf. No task needs to run: with the web
at desired 0 the partner host's default rule answers the ALB's 503, which still proves the path, so the edge is checked
at $0.
  python3 tools/terraform/crm_edge_live_check.py --cf-domain <distribution>.cloudfront.net

Checks (exit 1 if any fails):
  partner-root   https://<partner host>/        AA-979 clean-up: 301 to https://<agency host>/ (the partner
                                                distribution's CloudFront Function, crm_edge.tf)
  partner-path   https://<partner host>/crmx?x=1   301 to https://<agency host>/crmx?x=1: /crmx is not /crm or /crm/*,
                                                so it moves too, with its query
  partner-healthz https://<partner host>/healthz  301 to https://<agency host>/healthz (the web lives there now)
  crm-health     https://<partner host>/crm/health   200 = the API answers (crm_api rule, NOT redirected); 503 = the
                                                rule matched but aa-crm-dev-api has no healthy task (desired 0):
                                                reported, not failed (proves CloudFront -> VPC origin -> NLB -> ALB
                                                host + secret rule)
  client-root    https://<client host>/         AA-936: the CRM web off /c/* (crm_client_default): its 404 page (not
                                                JSON), or 503 = no healthy web task (reported, not failed)
  client-public  https://<client host>/crm/public/v1/forms/short   AA-936: the CRM API (crm_client_public): 422 JSON
                                                (the key is too short), or 503 = no healthy API task
  client-no-api  https://<client host>/crm/health   AA-936: NOT the API (only /crm/public/* is): the web's 404 page,
                                                or 503 (no healthy web task); a 200 JSON health answer fails
  raw-cf         https://<cf domain>/           403 "Forbidden" from the ALB deny rule (never CIS / Booking)
  api-header     https://<api host>/health + X-AA-Origin: guess   403 (deny rule) or 200 (header dropped),
                                                never the partner 404
  api-plain      https://<api host>/health      200 (CIS unchanged)
  booking        https://<booking host>/booking/health   200 (Booking unchanged)

AA-979 (CRM-P2b), only with --agency-cf-domain: the agency host portal.<zone> on its OWN distribution. The checks
connect to the distribution's *.cloudfront.net name and send SNI + Host = the agency host (the `curl --resolve` of the
runbook); pass --agency-direct to go through DNS (portal. points at the distribution since the S253 cutover).
  agency-root     https://<agency host>/              the CRM web (crm_agency_default): 307 to /auth/refresh, or 503
  agency-healthz  https://<agency host>/healthz       200 {"service": "aa-crm-web"} or 503 (no healthy web task)
  agency-studio   https://<agency host>/tenant-login  the Content studio (crm_agency_studio): since the clean-up 308 to
                                                     /auth/refresh?next=%2Fportal%2Fdashboard (API-key sign-in off),
                                                     or 503 (aa-crm-dev-portal at desired 0); never the web's 404 page
  agency-legal    https://<agency host>/terms         the Content studio (crm_agency_studio_x): 200 HTML, or 503
  agency-crm      https://<agency host>/crm/health    the CRM API (crm_agency_api): 200, or 503
  agency-raw-cf   https://<agency cf domain>/         403 "Forbidden" from the deny rule (no Host rule matches)
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


def get_via(connect_host: str, host: str, path: str, headers: dict | None = None,
            timeout: float = 30.0) -> tuple[int, bytes, str, str]:
    """Like :func:`get`, but the TCP / TLS connection goes to ``connect_host`` while SNI, certificate check and the
    Host header use ``host`` (the agency host before its DNS points at CloudFront: the wildcard certificate covers it)."""
    import socket
    import ssl

    ctx = ssl.create_default_context()
    raw = socket.create_connection((connect_host, 443), timeout=timeout)
    conn = http.client.HTTPSConnection(host, timeout=timeout, context=ctx)
    conn.sock = ctx.wrap_socket(raw, server_hostname=host)
    try:
        conn.request("GET", path, headers={"User-Agent": "aa979-edge-live-check", "Host": host, **(headers or {})})
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


def eval_client_web_404(status: int, body: bytes, ctype: str, location: str = "") -> Result:
    """The client host's default rule reaches the CRM web, which answers 404 off /c/* (an HTML page, never JSON)."""
    if status == 404 and _json(body) is None:
        return True, "status=404 page (AA-Partner web answers off /c/*)"
    if status == 503 and _json(body) is None:
        return True, "status=503 (rule matched, aa-crm-dev-web has no healthy task: desired 0?)"
    return False, f"status={status} type={ctype or '-'} body={body[:60]!r}"


def eval_client_public(status: int, body: bytes, ctype: str, location: str = "") -> Result:
    """/crm/public/* on the client host reaches the CRM API: a too-short form key is FastAPI's 422 JSON."""
    data = _json(body)
    if status == 422 and isinstance(data, dict) and "detail" in data:
        return True, "status=422 JSON (AA-Partner API answers /crm/public/*)"
    if status == 503 and not is_partner_404(status, body, ctype) and data is None:
        return True, "status=503 (rule matched, aa-crm-dev-api has no healthy task: desired 0?)"
    return False, f"status={status} type={ctype or '-'} body={body[:60]!r}"


def eval_studio_page(status: int, body: bytes, ctype: str, location: str = "") -> Result:
    """AA-979: a studio path on the agency host reaches the Content studio (a 200 HTML page), not the web."""
    if status == 200 and ctype.split(";")[0].strip() == "text/html" and b"aa-partner-web-404" not in body:
        return True, "status=200 page (Content studio answers)"
    if status == 503 and _json(body) is None:
        return True, "status=503 (rule matched, aa-crm-dev-portal has no healthy task: desired 0?)"
    return False, f"status={status} type={ctype or '-'} location={location or '-'} body={body[:60]!r}"


def moved_to(agency_host: str, path: str) -> Callable[..., Result]:
    """AA-979 clean-up: the partner host answers 301 to the same path (and query) on the agency host."""
    want = f"https://{agency_host}{path}"

    def evaluate(status: int, body: bytes, ctype: str, location: str = "") -> Result:
        if status == 301 and location == want:
            return True, f"status=301 -> {location}"
        return False, f"status={status} location={location or '-'} (expected 301 -> {want})"

    return evaluate


def studio_sign_in_gone(agency_host: str) -> Callable[..., Result]:
    """AA-979 clean-up: /tenant-login on the agency host is the studio's 308 to the CRM web's sign-in."""
    want = f"https://{agency_host}/auth/refresh?next=%2Fportal%2Fdashboard"

    def evaluate(status: int, body: bytes, ctype: str, location: str = "") -> Result:
        if status == 308 and location == want:
            return True, f"status=308 -> {location} (Content studio answers, API-key sign-in off)"
        if status == 503 and _json(body) is None:
            return True, "status=503 (rule matched, aa-crm-dev-portal has no healthy task: desired 0?)"
        return False, f"status={status} location={location or '-'} (expected 308 -> {want})"

    return evaluate


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

    checks = {
        "partner-root": run(moved_to(args.agency_host, "/"), args.host, "/"),
        "partner-path": run(moved_to(args.agency_host, "/crmx?x=1"), args.host, "/crmx?x=1"),
        "partner-healthz": run(moved_to(args.agency_host, "/healthz"), args.host, "/healthz"),
        "crm-health": run(eval_crm_health, args.host, "/crm/health"),
        "client-root": run(eval_client_web_404, args.client_host, "/"),
        "client-public": run(eval_client_public, args.client_host, "/crm/public/v1/forms/short"),
        "client-no-api": run(eval_client_web_404, args.client_host, "/crm/health"),
        "raw-cf": run(eval_raw_cf, args.cf_domain, "/"),
        "api-header": run(eval_api_header, args.api_host, "/health", GUESS_HEADER),
        "api-plain": run(eval_ok, args.api_host, "/health"),
        "booking": run(eval_ok, args.booking_host, "/booking/health"),
    }
    if args.agency_cf_domain:
        def agency(evaluate, path):
            if args.agency_direct:
                return lambda: evaluate(*get(args.agency_host, path))
            return lambda: evaluate(*get_via(args.agency_cf_domain, args.agency_host, path))

        checks.update({
            "agency-root": agency(eval_web_default, "/"),
            "agency-healthz": agency(eval_web_healthz, "/healthz"),
            "agency-studio": agency(studio_sign_in_gone(args.agency_host), "/tenant-login"),
            "agency-legal": agency(eval_studio_page, "/terms"),
            "agency-crm": agency(eval_crm_health, "/crm/health"),
            "agency-raw-cf": run(eval_raw_cf, args.agency_cf_domain, "/"),
        })
    return checks


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="AA-Partner CloudFront edge live checks (AA-931, AA-933, AA-935, AA-936)")
    ap.add_argument("--host", default="partner-dev.lumiguides.it.com")
    ap.add_argument("--client-host", default="go-dev.lumiguides.it.com", help="AA-936 client host (inquiry form)")
    ap.add_argument("--cf-domain", required=True, help="the distribution's *.cloudfront.net name (terraform output crm_edge)")
    ap.add_argument("--api-host", default="api-cis.lumiguides.it.com")
    ap.add_argument("--booking-host", default="api-booking.lumiguides.it.com")
    ap.add_argument("--agency-host", default="portal.lumiguides.it.com", help="AA-979 agency host (CRM + studio)")
    ap.add_argument("--agency-cf-domain", default="",
                    help="AA-979: the crm_agency distribution's *.cloudfront.net name (terraform output crm_agency_edge); "
                         "enables the agency checks, connecting to it with SNI / Host = --agency-host")
    ap.add_argument("--agency-direct", action="store_true",
                    help="AA-979: after the cutover, reach --agency-host through DNS instead of --agency-cf-domain")
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
        print(f"{'PASS' if ok else 'FAIL'}  {name:<13} {detail}", flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
