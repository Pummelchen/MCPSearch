#!/usr/bin/env python3
"""End-to-end smoke test for the SwiftWebSearchMCP stdio server.

Drives the built executable through a real MCP handshake and asserts that:

  1. ``initialize`` succeeds and reports the expected server identity;
  2. ``tools/list`` advertises every documented tool with a usable object schema —
     see ``REQUIRED_TOOLS`` for why this is a presence check rather than an exact
     inventory;
  3. every line written to stdout is valid JSON-RPC (a stray ``print`` anywhere in the
     server would corrupt the MCP stream, so this is checked on every reply);
  4. diagnostics are written to stderr, never stdout;
  5. ``web_search`` with no provider configured fails as a *tool* error with an
     actionable message rather than crashing the process.

It also covers the optional Streamable HTTP transport: with ``--http`` the server is
started on a loopback port, the full stateful session is exercised (session id, SSE
framing, tools/list, a tool call) and the negative cases are checked.

Usage:
    python3 scripts/mcp_smoke.py [--http] [path-to-SwiftWebSearchMCP]

With no argument the binary is located via ``swift build --show-bin-path``.
"""

from __future__ import annotations

import json
import os
import re
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from typing import Any

# Provider and synthesis variables are cleared so the run is hermetic: an exported API
# key must not change the outcome of this test.
#
# Kept in lockstep with ``ServerTestSupport.providerEnvironmentVariables`` in
# ``Tests/WebSearchCoreTests/TestSupport.swift``. The Swift suite is the source of
# truth; when it changes, change this tuple in the same commit so the two cannot drift.
SCRUBBED_VARIABLES = (
    "TAVILY_API_KEY",
    "BRAVE_SEARCH_API_KEY",
    "MOJEEK_API_KEY",
    "EXA_API_KEY",
    "JINA_API_KEY",
    "SEARXNG_BASE_URL",
    "OPEN_WEB_SEARCH_URL",
    "PARALLEL_MCP_URL",
    "SEARCH_ENABLE_SCRAPERS",
    "SEARCH_ENABLE_PARALLEL",
    "SEARCH_DISABLED_PROVIDERS",
    "SEARCH_PROVIDER_ORDER",
    "SEARCH_CONFIG_FILE",
    "DEEPSEEK_API_KEY",
    "DEEPSEEK_BASE_URL",
    "DEEPSEEK_MODEL",
    "SEARCH_SYNTHESIS_TIMEOUT_MS",
    "SEARCH_SYNTHESIS_REASONING",
)

# The documented tool surface. Deliberately a *presence* check rather than an exact
# inventory: which tools exist, and the schema rules each must satisfy, are asserted in
# Swift (``StdioServerTests`` names and counts them, ``SchemaCompatibilityTests`` lints
# every schema) and that suite runs in the same CI job. Keeping a second exhaustive list
# here is what let a fourth tool ship while this script still demanded three, which turned
# CI red for a release that was otherwise correct. Adding a tool must not require editing
# two languages in lockstep.
REQUIRED_TOOLS = ("web_answer", "web_open", "web_search", "web_search_status")


class Failure(Exception):
    """A smoke-test assertion failed."""


def locate_binary() -> str:
    positional = [a for a in sys.argv[1:] if not a.startswith("--")]
    if positional:
        return positional[0]
    try:
        out = subprocess.run(
            ["swift", "build", "--show-bin-path"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError) as error:
        raise Failure(f"could not determine the build path: {error}") from error
    return os.path.join(out, "SwiftWebSearchMCP")


class Server:
    """A running server with newline-delimited JSON-RPC framing."""

    def __init__(self, binary: str) -> None:
        environment = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "SEARCH_LOG_LEVEL": "debug",
        }
        for name in SCRUBBED_VARIABLES:
            environment.pop(name, None)

        self.process = subprocess.Popen(
            [binary],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            text=True,
            bufsize=1,
        )
        self._next_id = 0

    def send(self, payload: dict[str, Any]) -> None:
        assert self.process.stdin is not None
        self.process.stdin.write(json.dumps(payload) + "\n")
        self.process.stdin.flush()

    def read_message(self) -> dict[str, Any]:
        """Read one stdout line and assert it is valid JSON."""
        assert self.process.stdout is not None
        line = self.process.stdout.readline()
        if not line:
            raise Failure(f"server closed stdout early; stderr:\n{self.stderr_text()}")
        try:
            message = json.loads(line)
        except json.JSONDecodeError as error:
            raise Failure(
                f"stdout is not valid JSON (protocol stream corrupted): {error}\n"
                f"offending line: {line!r}"
            ) from error
        if not isinstance(message, dict):
            raise Failure(f"expected a JSON object on stdout, got: {line!r}")
        return message

    def request(self, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        self._next_id += 1
        request_id = self._next_id
        payload: dict[str, Any] = {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": method,
        }
        if params is not None:
            payload["params"] = params
        self.send(payload)

        # Skip notifications; this server sends none, but be tolerant.
        while True:
            message = self.read_message()
            if message.get("id") == request_id:
                return message

    def notify(self, method: str) -> None:
        self.send({"jsonrpc": "2.0", "method": method})

    def stderr_text(self) -> str:
        assert self.process.stderr is not None
        try:
            return self.process.stderr.read()
        except OSError, ValueError:  # pragma: no cover - best effort in a failure path
            return "<unavailable>"

    def close(self) -> int:
        assert self.process.stdin is not None
        self.process.stdin.close()
        return self.process.wait(timeout=30)


def check_initialize(server: Server) -> None:
    response = server.request(
        "initialize",
        {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "mcp_smoke", "version": "1.0.0"},
        },
    )
    result = response.get("result")
    if not isinstance(result, dict):
        raise Failure(f"initialize returned no result: {response}")
    info = result.get("serverInfo", {})
    if info.get("name") != "SwiftWebSearchMCP":
        raise Failure(f"unexpected server name: {info}")
    if not result.get("protocolVersion"):
        raise Failure("initialize did not negotiate a protocol version")
    print(f"  initialize ok (server={info.get('name')} {info.get('version')})")

    server.notify("notifications/initialized")


def check_tools(server: Server) -> None:
    response = server.request("tools/list")
    tools = response.get("result", {}).get("tools")
    if not isinstance(tools, list):
        raise Failure(f"tools/list returned no tools: {response}")
    names = {tool.get("name") for tool in tools}
    missing = set(REQUIRED_TOOLS) - names
    if missing:
        raise Failure(f"tools/list is missing {sorted(missing)}; advertised {sorted(names)}")
    undocumented = names - set(REQUIRED_TOOLS)
    if undocumented:
        # Not a failure: the Swift suite owns the exact inventory. Printed so a new tool
        # is visible in the smoke log instead of silently accepted.
        print(f"  note: {sorted(undocumented)} advertised but not listed in this script")

    for tool in tools:
        schema = tool.get("inputSchema")
        if not isinstance(schema, dict) or schema.get("type") != "object":
            raise Failure(f"tool {tool.get('name')} has no object inputSchema")
        if not isinstance(schema.get("properties"), dict):
            raise Failure(f"tool {tool.get('name')} has no properties")

    search = next(t for t in tools if t["name"] == "web_search")
    properties = set(search["inputSchema"]["properties"])
    expected_properties = {
        "query",
        "max_results",
        "recency",
        "include_domains",
        "exclude_domains",
        "locale",
        "provider",
        "mode",
    }
    if properties != expected_properties:
        raise Failure(
            f"web_search schema drifted: {sorted(properties)} != {sorted(expected_properties)}"
        )
    print(f"  tools/list ok ({len(tools)} tools, schema verified)")


def check_unconfigured_search_is_a_tool_error(server: Server) -> str:
    """With no provider configured, a search must fail cleanly and helpfully."""
    response = server.request(
        "tools/call",
        {"name": "web_search", "arguments": {"query": "swift concurrency"}},
    )
    result = response.get("result")
    if not isinstance(result, dict):
        raise Failure(f"tools/call returned no result: {response}")
    if result.get("isError") is not True:
        raise Failure(f"expected isError=true with no provider configured: {result}")
    text = " ".join(
        block.get("text", "") for block in result.get("content", []) if isinstance(block, dict)
    )
    if "TAVILY_API_KEY" not in text and "not configured" not in text:
        raise Failure(f"error message is not actionable: {text!r}")
    print("  web_search without a provider fails as an actionable tool error")
    return text


# ---------------------------------------------------------------------------
# Streamable HTTP transport
# ---------------------------------------------------------------------------


def http_exchange(
    port: int,
    body: dict[str, Any],
    session: str | None = None,
    accept: str = "application/json, text/event-stream",
    path: str = "/mcp",
    origin: str | None = None,
):
    """POST one JSON-RPC message and return (status, headers, messages).

    The response is either a complete JSON body (initialize) or a chunked
    Server-Sent Events stream (everything else), so both framings are decoded here.
    """
    payload = json.dumps(body).encode()
    request = (
        f"POST {path} HTTP/1.1\r\n"
        f"Host: 127.0.0.1:{port}\r\n"
        f"Content-Type: application/json\r\n"
        f"Accept: {accept}\r\n"
        f"Content-Length: {len(payload)}\r\n"
    )
    if session:
        request += f"Mcp-Session-Id: {session}\r\n"
    if origin:
        request += f"Origin: {origin}\r\n"
    request += "Connection: close\r\n\r\n"

    with socket.create_connection(("127.0.0.1", port), timeout=20) as connection:
        connection.sendall(request.encode() + payload)
        raw = b""
        while True:
            try:
                chunk = connection.recv(65536)
            except TimeoutError:
                break
            if not chunk:
                break
            raw += chunk

    text = raw.decode("utf-8", "replace")
    head, _, rest = text.partition("\r\n\r\n")
    status_line = head.split("\r\n")[0]
    status = int(status_line.split()[1]) if len(status_line.split()) > 1 else 0

    headers: dict[str, str] = {}
    for line in head.split("\r\n")[1:]:
        if ":" in line:
            name, value = line.split(":", 1)
            headers[name.strip().lower()] = value.strip()

    # De-chunk if the body is chunked.
    if headers.get("transfer-encoding", "").lower() == "chunked":
        pieces, remaining = [], rest
        while True:
            index = remaining.find("\r\n")
            if index < 0:
                break
            try:
                size = int(remaining[:index].split(";")[0], 16)
            except ValueError:
                break
            if size == 0:
                break
            pieces.append(remaining[index + 2 : index + 2 + size])
            remaining = remaining[index + 2 + size + 2 :]
        rest = "".join(pieces)

    messages = [json.loads(m) for m in re.findall(r"^data: (\{.*\})$", rest, re.MULTILINE)]
    if not messages and rest.strip().startswith("{"):
        messages = [json.loads(rest)]
    return status, headers, messages


def wait_for_health(port: int, timeout: float = 20.0) -> None:
    """Poll /health until the HTTP transport is accepting connections."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=2) as response:
                if response.status == 200:
                    return
        except urllib.error.URLError, ConnectionError, OSError:
            time.sleep(0.25)
    raise Failure(f"HTTP transport did not become healthy on port {port}")


def free_loopback_port() -> int:
    """Ask the OS for an unused loopback port.

    A fixed port would make two concurrent smoke runs collide, which matters because
    this script is cheap enough to run in parallel.
    """
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def run_http_smoke(binary: str) -> None:
    """Start the server in HTTP mode and exercise the Streamable HTTP transport."""
    port = free_loopback_port()
    environment = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "SEARCH_LOG_LEVEL": "info",
    }

    process = subprocess.Popen(
        [binary, "--transport", "http", "--port", str(port)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
        text=True,
    )
    try:
        wait_for_health(port)
        print(f"  /health ok on port {port}")

        status, headers, messages = http_exchange(
            port,
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {},
                    "clientInfo": {"name": "mcp_smoke_http", "version": "1.0.0"},
                },
            },
        )
        if status != 200 or not messages:
            raise Failure(f"HTTP initialize failed: status={status} messages={messages}")
        session = headers.get("mcp-session-id")
        if not session:
            raise Failure("HTTP initialize did not return an Mcp-Session-Id header")
        print(
            f"  initialize ok over HTTP (session issued, protocol "
            f"{messages[0]['result']['protocolVersion']})"
        )

        status, _, _ = http_exchange(
            port, {"jsonrpc": "2.0", "method": "notifications/initialized"}, session
        )
        if status != 202:
            raise Failure(f"expected 202 for notifications/initialized, got {status}")
        print("  notifications/initialized accepted (202)")

        status, _, messages = http_exchange(
            port, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}, session
        )
        if status != 200 or not messages:
            raise Failure(f"HTTP tools/list failed: status={status}")
        names = {tool["name"] for tool in messages[0]["result"]["tools"]}
        missing = set(REQUIRED_TOOLS) - names
        if missing:
            raise Failure(
                f"HTTP tools/list is missing {sorted(missing)}; advertised {sorted(names)}"
            )
        print("  tools/list ok over SSE")

        status, _, messages = http_exchange(
            port,
            {
                "jsonrpc": "2.0",
                "id": 3,
                "method": "tools/call",
                "params": {"name": "web_search_status", "arguments": {}},
            },
            session,
        )
        if status != 200 or not messages or messages[0]["result"].get("isError"):
            raise Failure(f"HTTP tools/call failed: status={status} messages={messages}")
        print("  tools/call ok over SSE")

        # Negative cases: these must be refused rather than silently served.
        status, _, _ = http_exchange(
            port, {"jsonrpc": "2.0", "id": 4, "method": "tools/list"}, None
        )
        if status < 400:
            raise Failure(f"a request without a session id should be refused, got {status}")

        status, _, _ = http_exchange(
            port,
            {"jsonrpc": "2.0", "id": 5, "method": "tools/list"},
            session,
            accept="application/json",
        )
        if status < 400:
            raise Failure(f"a request that cannot accept SSE should be refused, got {status}")

        status, _, _ = http_exchange(
            port,
            {"jsonrpc": "2.0", "id": 6, "method": "tools/list"},
            session,
            origin="https://evil.example.com",
        )
        if status < 400:
            raise Failure(f"a cross-origin request should be refused, got {status}")
        print("  negative cases refused (no session, no SSE accept, cross-origin)")

        # stdout must stay empty in HTTP mode: it carries no protocol traffic.
        process.terminate()
        stdout, _ = process.communicate(timeout=20)
        if stdout.strip():
            raise Failure(f"HTTP mode wrote to stdout: {stdout[:200]!r}")
        print("  stdout remained empty in HTTP mode")
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=10)


def main() -> int:
    binary = locate_binary()
    if not os.path.isfile(binary):
        raise Failure(f"server binary not found at {binary}; run `swift build` first")

    print(f"smoke-testing {binary}")
    server = Server(binary)
    try:
        check_initialize(server)
        check_tools(server)
        check_unconfigured_search_is_a_tool_error(server)

        # Confirm diagnostics went to stderr rather than stdout.
        exit_code = server.close()
        if exit_code != 0:
            raise Failure(f"server exited with code {exit_code}")

        # stdout has been drained line by line above; every line parsed as JSON, which
        # is the property under test. stderr must carry the startup diagnostics.
        stderr = server.stderr_text()
        if "SwiftWebSearchMCP" not in stderr:
            raise Failure(f"expected startup diagnostics on stderr, got: {stderr[:400]!r}")
        print("  stdout carried only valid JSON-RPC; diagnostics appeared on stderr")
    finally:
        if server.process.poll() is None:
            server.process.kill()

    if "--http" in sys.argv:
        print("smoke-testing the Streamable HTTP transport")
        run_http_smoke(binary)

    print("SMOKE TEST PASSED")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Failure as failure:
        print(f"SMOKE TEST FAILED: {failure}", file=sys.stderr)
        sys.exit(1)
