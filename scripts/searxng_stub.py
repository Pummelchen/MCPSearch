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
from typing import cast


class _StubState:
    """One stub's scripted response and the paths it has served."""

    def __init__(self, status: int, payload: str) -> None:
        self.status = status
        self.payload = payload
        self.requests: list[str] = []


class _StubServer(ThreadingHTTPServer):
    """`ThreadingHTTPServer` carrying this instance's scripted state.

    The attribute is declared here so a type checker can see it: the handler reaches it through
    `self.server`, which is typed as the base server (ledger A0024).
    """

    stub_state: _StubState

    def __init__(self, address: tuple[str, int], state: _StubState) -> None:
        super().__init__(address, _StubHandler)
        self.stub_state = state


class _StubHandler(BaseHTTPRequestHandler):
    """Answers `/search` the way a SearXNG instance would, or with a scripted status.

    The scripted state hangs off the *server*, not the handler class. It used to be class attributes
    on this handler, set by each `StubSearXNG.__init__` — so two instances shared one `status`, one
    `payload` and one `requests` list, and building the second silently reset the first's recorded
    paths and changed what the first would answer. The old docstring said callers must therefore not
    share a server, which is a rule nothing enforced (ledger A0024).
    """

    def do_GET(self) -> None:
        state = cast(_StubServer, self.server).stub_state
        state.requests.append(self.path)
        body = state.payload.encode("utf-8")
        self.send_response(state.status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:
        """Silence the stub: its access log would drown the test output."""


class StubSearXNG:
    """A loopback SearXNG stub on an ephemeral port."""

    def __init__(self, status: int = 200, payload: str = "{}") -> None:
        self.state = _StubState(status=status, payload=payload)
        # The handler reaches this through `self.server`, so the state belongs to this instance and
        # only to it (ledger A0024).
        self.server = _StubServer(("127.0.0.1", 0), self.state)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    @property
    def base_url(self) -> str:
        host, port = self.server.server_address[:2]
        return f"http://{host}:{port}"

    @property
    def requests(self) -> list[str]:
        """The paths served so far, so a caller can prove the instance was actually asked."""
        return list(self.state.requests)

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
