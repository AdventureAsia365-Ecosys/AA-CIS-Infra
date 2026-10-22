"""Tests of the AA-931 hello server (accounts/aa365/assets/crm_spike/server.py). Offline, stdlib + pytest."""
from __future__ import annotations

import http.client
import importlib.util
import json
import threading
import time
from pathlib import Path

import pytest

SERVER = Path(__file__).resolve().parents[3] / "accounts" / "aa365" / "assets" / "crm_spike" / "server.py"


@pytest.fixture(scope="module")
def port():
    spec = importlib.util.spec_from_file_location("crm_spike_server", SERVER)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod.Handler.log_message = lambda *a, **k: None
    srv = mod.ThreadingHTTPServer(("127.0.0.1", 0), mod.Handler)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    yield srv.server_address[1]
    srv.shutdown()


def _get(port, path, headers=None):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    c.request("GET", path, headers=headers or {})
    r = c.getresponse()
    return r, r.read()


def test_health(port):
    r, body = _get(port, "/health")
    assert r.status == 200 and body == b"ok\n"


def test_index_is_chunked_html(port):
    r, body = _get(port, "/")
    assert r.status == 200
    assert r.getheader("Transfer-Encoding") == "chunked"
    assert b"AA-Partner spike" in body


def test_stream_sends_chunks_over_time(port):
    t0 = time.monotonic()
    r, body = _get(port, "/stream?seconds=2")
    assert r.status == 200
    assert body.count(b"chunk ") == 2 and b"done after" in body
    assert time.monotonic() - t0 >= 2


def test_stream_seconds_capped():
    spec = importlib.util.spec_from_file_location("s2", SERVER)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    assert mod._seconds("seconds=999", mod.MAX_STREAM_SECONDS, 30) == 60
    assert mod._seconds("seconds=-5", 60, 30) == 0
    assert mod._seconds("seconds=x", 60, 30) == 30


def test_whoami_never_echoes_origin_secret(port):
    r, body = _get(port, "/whoami", {"X-AA-Origin": "topsecretvalue", "X-Forwarded-For": "1.2.3.4"})
    data = json.loads(body)
    assert data["origin_header_present"] is True
    assert data["headers"]["X-Forwarded-For"] == "1.2.3.4"
    assert b"topsecretvalue" not in body


def test_unknown_path_404(port):
    r, _ = _get(port, "/nope")
    assert r.status == 404
