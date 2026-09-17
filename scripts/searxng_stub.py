#!/usr/bin/env python3
"""A loopback SearXNG stub, shared by the harnesses that need one.

Two callers want the same thing and neither should own it: `harness_tests.py` drives
`searxng_health.py` against a scripted instance, and `dual_client_contract.py` points both
executables at **one** instance so it can compare what each reports. It was defined inside
`harness_tests.py` until the second caller existed, and a test module is the wrong place to
import a server from.

It answers any path with the same scripted status and body, which is all a caller needs: every
reader fetches `/search` and reads the JSON body.

Usage:
    from searxng_stub import StubSearXNG   # via importlib, since `scripts/` is not a package
"""

from __future__ import annotations

import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import ClassVar


class _StubHandler(BaseHTTPRequestHandler):
    """Answers `/search` the way a SearXNG instance would, or with a scripted status.

    Class attributes are set per server instance (`status`, `payload`) and read on the request
    thread, which is why each caller builds its own server rather than sharing one.
    """

    status = 200
    payload: str = "{}"
    requests: ClassVar[list[str]] = []

    def do_GET(self) -> None:
        type(self).requests.append(self.path)
        body = self.payload.encode("utf-8")
        self.send_response(self.status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:
        """Silence the stub: its access log would drown the test output."""


class StubSearXNG:
    """A loopback SearXNG stub on an ephemeral port."""

    def __init__(self, status: int = 200, payload: str = "{}") -> None:
        _StubHandler.status = status
        _StubHandler.payload = payload
        _StubHandler.requests = []
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), _StubHandler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    @property
    def base_url(self) -> str:
        host, port = self.server.server_address[:2]
        return f"http://{host}:{port}"

    @property
    def requests(self) -> list[str]:
        """The paths served so far, so a caller can prove the instance was actually asked."""
        return list(_StubHandler.requests)

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
