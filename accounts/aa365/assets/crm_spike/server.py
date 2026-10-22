"""AA-931 (CRM-03) spike: a tiny HTTP server behind CloudFront -> VPC origin -> NLB -> ALB.

Stdlib only. The ECS task runs it with `python3 -c "<this file>"` on the public python:3.12-slim
image, so there is no image to build or push. It proves the edge path, nothing else: no data, no
auth, no state.

Endpoints
  GET /health            200 "ok" (ALB target group health check)
  GET /                  small HTML page, sent in two flushed chunks (chunked transfer)
  GET /stream?seconds=N  one line per second for N seconds (N <= 60): streamed SSR stand-in
  GET /slow?seconds=N    nothing for N seconds, then one line (N <= 55): first-byte latency check
  GET /whoami            JSON: Host, X-Forwarded-For, CloudFront-Viewer-* headers, and whether the
                         origin header was present. The origin header's VALUE is never echoed.

PORT comes from the environment (default 8080).
"""

from __future__ import annotations

import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

ORIGIN_HEADER = "X-AA-Origin"
MAX_STREAM_SECONDS = 60
MAX_SLOW_SECONDS = 55
ECHO_HEADERS = (
    "Host",
    "X-Forwarded-For",
    "X-Forwarded-Proto",
    "X-Amzn-Trace-Id",
    "CloudFront-Viewer-Address",
    "CloudFront-Viewer-Country",
    "CloudFront-Forwarded-Proto",
    "Via",
)


def _seconds(query: str, cap: int, default: int) -> int:
    raw = parse_qs(query).get("seconds", [str(default)])[0]
    try:
        value = int(raw)
    except ValueError:
        value = default
    return max(0, min(value, cap))


def whoami(headers) -> dict:
    """What the container saw. Never includes the origin header value."""
    seen = {name: headers.get(name) for name in ECHO_HEADERS if headers.get(name) is not None}
    return {
        "app": "aa-crm-spike",
        "headers": seen,
        "origin_header_present": headers.get(ORIGIN_HEADER) is not None,
    }


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "aa-crm-spike"
    sys_version = ""

    def log_message(self, fmt, *args):  # one compact line per request on stdout (awslogs)
        print(f"{self.command} {urlparse(self.path).path} {fmt % args}", flush=True)

    def _send(self, status: int, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _start_chunked(self, content_type: str) -> None:
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Transfer-Encoding", "chunked")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()

    def _chunk(self, data: bytes) -> None:
        self.wfile.write(b"%x\r\n%s\r\n" % (len(data), data))
        self.wfile.flush()

    def _end_chunked(self) -> None:
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()

    def do_GET(self):  # noqa: N802 (stdlib name)
        url = urlparse(self.path)
        if url.path == "/health":
            self._send(200, b"ok\n", "text/plain; charset=utf-8")
        elif url.path == "/whoami":
            self._send(200, json.dumps(whoami(self.headers), sort_keys=True).encode() + b"\n", "application/json")
        elif url.path == "/":
            self._start_chunked("text/html; charset=utf-8")
            self._chunk(b"<!doctype html><html><head><title>AA-Partner spike</title></head><body>")
            self._chunk(b"<h1>AA-Partner spike</h1><p>CloudFront &rarr; VPC origin &rarr; NLB &rarr; ALB &rarr; Fargate.</p></body></html>\n")
            self._end_chunked()
        elif url.path == "/stream":
            seconds = _seconds(url.query, MAX_STREAM_SECONDS, 30)
            self._start_chunked("text/plain; charset=utf-8")
            started = time.monotonic()
            for i in range(seconds):
                self._chunk(f"chunk {i + 1}/{seconds} t={time.monotonic() - started:.1f}s\n".encode())
                time.sleep(1)
            self._chunk(f"done after {time.monotonic() - started:.1f}s\n".encode())
            self._end_chunked()
        elif url.path == "/slow":
            seconds = _seconds(url.query, MAX_SLOW_SECONDS, 30)
            time.sleep(seconds)
            self._send(200, f"slept {seconds}s\n".encode(), "text/plain; charset=utf-8")
        else:
            self._send(404, b"not found\n", "text/plain; charset=utf-8")

    def do_HEAD(self):  # noqa: N802
        self._send(200 if urlparse(self.path).path in ("/", "/health") else 404, b"", "text/plain")


def main() -> None:
    port = int(os.environ.get("PORT", "8080"))
    ThreadingHTTPServer.daemon_threads = True
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)  # noqa: S104 (container port behind the ALB)
    print(f"aa-crm-spike listening on :{port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
