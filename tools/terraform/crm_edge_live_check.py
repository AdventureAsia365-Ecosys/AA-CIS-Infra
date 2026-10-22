#!/usr/bin/env python3
"""AA-931 (CRM-03) live checks of the CloudFront -> VPC origin -> NLB -> ALB spike. Stdlib only, no AWS calls.

Run after the apply, with the spike service scaled to 1 and healthy:
  python3 tools/terraform/crm_edge_live_check.py --cf-domain <distribution>.cloudfront.net

Checks (exit 1 if any fails):
  partner      https://<partner host>/              200, the spike page
  raw-cf       https://<cf domain>/                 403 "Forbidden" from the ALB deny rule (never CIS / Booking)
  stream-30s   /stream?seconds=30                   200, 30 chunks, >= 30 s, not cut
  slow-35s     /slow?seconds=35                     200 after 35 s (origin read timeout 60 s, not the 30 s default)
  api-header   https://<api host>/health + X-AA-Origin: guess   403 (deny rule) or 200 (header dropped), never the spike
  api-plain    https://<api host>/health            200 (CIS unchanged)
  booking      https://<booking host>/booking/health 200 (Booking unchanged)
  whoami       prints what the container saw (X-Forwarded-For, CloudFront-Viewer-Country): tells whether the
               ALB saw a CloudFront edge address (client IP preserved by the NLB) or a VPC address
The "country outside the WAF list" check needs a viewer outside US/GB/AU/SG/VN/IN/JP/TH/NZ/CA (VPN): run
  --only partner,stream-30s from there; and the WAF sampled requests must show CloudFrontOriginAllow.
"""
from __future__ import annotations

import argparse
import http.client
import json
import sys
import time

GUESS_HEADER = {"X-AA-Origin": "aa931-live-check-guess"}  # deliberately wrong: must be refused


def get(host: str, path: str, headers: dict | None = None, timeout: float = 90.0):
    t0 = time.monotonic()
    conn = http.client.HTTPSConnection(host, timeout=timeout)
    conn.request("GET", path, headers={"User-Agent": "aa931-live-check", **(headers or {})})
    resp = conn.getresponse()
    chunks = 0
    body = b""
    while True:
        part = resp.read1(65536) if hasattr(resp, "read1") else resp.read(65536)
        if not part:
            break
        chunks += part.count(b"chunk ")
        body += part
    conn.close()
    return resp.status, body, time.monotonic() - t0, chunks


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="AA-931 CloudFront VPC-origin spike live checks")
    ap.add_argument("--host", default="partner-dev.lumiguides.it.com")
    ap.add_argument("--cf-domain", required=True, help="the distribution's *.cloudfront.net name (terraform output crm_edge_spike)")
    ap.add_argument("--api-host", default="api-cis.lumiguides.it.com")
    ap.add_argument("--booking-host", default="api-booking.lumiguides.it.com")
    ap.add_argument("--only", default="", help="comma list of check names")
    args = ap.parse_args(argv)
    only = {c for c in args.only.split(",") if c}

    checks = {
        "partner": lambda: (lambda s, b, t, c: (s == 200 and b"AA-Partner spike" in b, f"status={s} t={t:.1f}s"))(*get(args.host, "/")),
        "raw-cf": lambda: (lambda s, b, t, c: (s == 403 and b.strip() == b"Forbidden", f"status={s} body={b[:40]!r}"))(*get(args.cf_domain, "/")),
        "stream-30s": lambda: (lambda s, b, t, c: (s == 200 and c >= 30 and b"done after" in b and t >= 30, f"status={s} chunks={c} t={t:.1f}s"))(*get(args.host, "/stream?seconds=30")),
        "slow-35s": lambda: (lambda s, b, t, c: (s == 200 and b"slept 35s" in b, f"status={s} t={t:.1f}s"))(*get(args.host, "/slow?seconds=35")),
        # 403 = API Gateway forwarded the header and the ALB deny rule caught it; 200 = API Gateway dropped
        # it (also safe). Never the partner page.
        "api-header": lambda: (lambda s, b, t, c: (s in (200, 403) and b"AA-Partner spike" not in b, f"status={s}"))(*get(args.api_host, "/health", GUESS_HEADER)),
        "api-plain": lambda: (lambda s, b, t, c: (s == 200, f"status={s}"))(*get(args.api_host, "/health")),
        "booking": lambda: (lambda s, b, t, c: (s == 200, f"status={s}"))(*get(args.booking_host, "/booking/health")),
    }
    failed = 0
    for name, fn in checks.items():
        if only and name not in only:
            continue
        try:
            ok, detail = fn()
        except Exception as exc:  # noqa: BLE001 - report and continue
            ok, detail = False, f"error {type(exc).__name__}: {exc}"
        failed += 0 if ok else 1
        print(f"{'PASS' if ok else 'FAIL'}  {name:<11} {detail}", flush=True)

    if not only or "whoami" in only:
        try:
            s, b, _, _ = get(args.host, "/whoami")
            print(f"INFO  whoami      status={s} {json.dumps(json.loads(b), sort_keys=True)}")
        except Exception as exc:  # noqa: BLE001
            print(f"INFO  whoami      error {exc}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
