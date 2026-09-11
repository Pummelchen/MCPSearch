#!/usr/bin/env python3
"""End-to-end smoke test for the SwiftWebSearchMCP stdio server.

Drives the built executable through a real MCP handshake and asserts that:

  1. ``initialize`` succeeds and reports the expected server identity;
  2. ``tools/list`` exposes exactly the three documented tools;
  3. every line written to stdout is valid JSON-RPC (a stray ``print`` anywhere in the
     server would corrupt the MCP stream, so this is checked on every reply);
  4. diagnostics are written to stderr, never stdout;
  5. ``web_search`` with no provider configured fails as a *tool* error with an
     actionable message rather than crashing the process.

The client follows the transport contract by keeping stdin open until all replies have
been read. Closing stdin immediately after writing would race the server's shutdown,
which is a property of clients, not of this server.

Usage:
    python3 scripts/mcp_smoke.py [path-to-SwiftWebSearchMCP]

With no argument the binary is located via ``swift build --show-bin-path``.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from typing import Any

# Provider variables are cleared so the run is hermetic: an exported API key must not
# change the outcome of this test.
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
    "SEARCH_CONFIG_FILE",
)

EXPECTED_TOOLS = {"web_search", "web_open", "web_search_status"}


class Failure(Exception):
    """A smoke-test assertion failed."""


def locate_binary() -> str:
    if len(sys.argv) > 1:
        return sys.argv[1]
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
        except Exception:  # pragma: no cover - best effort in a failure path
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
    if names != EXPECTED_TOOLS:
        raise Failure(f"expected tools {sorted(EXPECTED_TOOLS)}, got {sorted(names)}")

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


def check_unconfigured_search_is_a_tool_error(server: Server) -> None:
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

    print("SMOKE TEST PASSED")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Failure as failure:
        print(f"SMOKE TEST FAILED: {failure}", file=sys.stderr)
        sys.exit(1)
