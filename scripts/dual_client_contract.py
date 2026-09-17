#!/usr/bin/env python3
"""One SearXNG instance, two executables — the contract between them.

`harness_tests.py` owns the half of this contract that is static: the provider environment scrub
list in `mcp_smoke.py` must be the same set as the Swift harnesses', because a drift leaves a
developer's exported key visible to a child that believes it scrubbed. This is the other half, and
it is runtime. `SwiftWebSearchMCP` and `mcps-mon` read the *same* SearXNG instance through two
independent parsers — `SearXNGProvider` and `NodeProbe` — and nothing asserted that they agree
about what they read.

They have disagreed before. `NodeProbe` did not map `unresponsive_engines` at all, so the
dashboard's unavailable-engine column was empty against every live instance while the provider
mapped the same key explicitly. No Swift test can catch that class of drift: each side's tests pass
on its own, because the disagreement exists only *between* them.

So both binaries are pointed at one stub and each is asked what it sees. Comparing the two answers
to each other alone would pass if both drifted the same way, so each is compared against the value
the stub was told to return — the two therefore agree by construction rather than by coincidence.

The payload avoids `", "` and `": "` inside a reason, which are the separators the dashboard's
renderer joins and delimits with; a reason containing one could not be read back.

Usage:
    python3 scripts/dual_client_contract.py [bin-dir]
"""

from __future__ import annotations

import importlib.util
import json
import os
import re
import subprocess
import sys
import types
from functools import partial
from pathlib import Path
from typing import Any, cast

SCRIPTS = Path(__file__).resolve().parent


class Failure(Exception):
    """A contract violation, reported as a verdict rather than a traceback."""


def load_script(name: str) -> types.ModuleType:
    """Import a sibling script by path, since `scripts/` is not a package."""
    path = SCRIPTS / f"{name}.py"
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise Failure(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


mcp_smoke = load_script("mcp_smoke")
monitor_tty_smoke = load_script("monitor_tty_smoke")
searxng_stub = load_script("searxng_stub")

# What the stub is told to report: two engines down and one answering. Two rather than one, so a
# parser that reads only the first entry and one that drops the field both fail instead of
# coincidentally matching.
UNAVAILABLE: tuple[tuple[str, str], ...] = (("duckduckgo", "CAPTCHA"), ("mojeek", "timeout"))
HEALTHY_ENGINE = "stub-engine"
QUERY = "swift concurrency"

# How the provider phrases it, in `SearXNGProvider`.
WARNING = re.compile(r"^SearXNG engine (?P<engine>.+) was unresponsive: (?P<reason>.+)\.$")
# How the dashboard words an instance that answered with nothing, in `NodeProbe`.
EMPTY_REPORT = "no results returned"


def payload(answering_engine: str | None, unavailable: tuple[tuple[str, str], ...]) -> str:
    """A SearXNG JSON body: results from one engine, and the engines that did not answer."""
    results: list[dict[str, str]] = []
    if answering_engine is not None:
        results.append(
            {
                "title": "Stub result",
                "url": "https://example.com/stub",
                "content": "stub content",
                "engine": answering_engine,
            }
        )
    return json.dumps(
        {
            "query": QUERY,
            "results": results,
            "unresponsive_engines": [list(pair) for pair in unavailable],
        }
    )


def binaries() -> tuple[str, str]:
    """The two binaries, from the first positional argument or from the SwiftPM build path."""
    positional = [argument for argument in sys.argv[1:] if not argument.startswith("--")]
    if positional:
        directory = positional[0]
    else:
        try:
            directory = subprocess.run(
                ["swift", "build", "--show-bin-path"],
                capture_output=True,
                text=True,
                check=True,
            ).stdout.strip()
        except (subprocess.CalledProcessError, FileNotFoundError) as error:
            raise Failure(f"could not determine the build path: {error}") from error
    server = os.path.join(directory, "SwiftWebSearchMCP")
    monitor = os.path.join(directory, "mcps-mon")
    for path in (server, monitor):
        if not os.path.exists(path):
            raise Failure(f"no binary at {path}")
    return server, monitor


def server_view(server_binary: str, stub_url: str) -> dict[str, Any]:
    """What the MCP server reports about the instance, as a `web_search` tool result."""
    server = mcp_smoke.Server(server_binary, {"SEARXNG_BASE_URL": stub_url})
    try:
        handshake = server.request(
            "initialize",
            {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "dual_client_contract", "version": "1.0.0"},
            },
        )
        if not isinstance(handshake.get("result"), dict):
            raise Failure(f"initialize returned no result: {handshake}")
        server.notify("notifications/initialized")
        response = server.request(
            "tools/call", {"name": "web_search", "arguments": {"query": QUERY}}
        )
    finally:
        server.close()
    result = response.get("result")
    if not isinstance(result, dict):
        raise Failure(f"tools/call returned no result: {response}")
    return cast("dict[str, Any]", result)


def painted_a_frame(session: Any) -> bool:
    """Whether the dashboard has drawn a complete frame yet."""
    return bool(session.frames())


def frame_contains(session: Any, text: str) -> bool:
    """Whether the most recent frame contains `text`."""
    return text in session.frame_text()


def monitor_view(monitor_binary: str, stub_url: str, awaited: str) -> str:
    """What the dashboard paints for the instance: the text of its most recent frame."""
    session = monitor_tty_smoke.Session(monitor_binary, stub_url)
    try:
        session.wait_for(painted_a_frame, "the first frame")
        # Colour off before reading text. The renderer truncates each row's detail to the terminal
        # width, and escape sequences count towards that budget, so with colour on the tail of the
        # column being compared can be cut off. The dashboard's own smoke test toggles it the same
        # way before asserting on text.
        session.send("c")
        session.wait_for(partial(frame_contains, text=awaited), f"{awaited!r} to be drawn")
        session.drain(0.5)
        return monitor_tty_smoke.ANSI.sub("", session.frames()[-1])
    finally:
        session.close()


def parse_warnings(warnings: list[str]) -> set[tuple[str, str]]:
    """The (engine, reason) pairs the server named, read out of its own phrasing."""
    parsed: set[tuple[str, str]] = set()
    for warning in warnings:
        match = WARNING.match(warning)
        if match is None:
            raise Failure(f"the server phrased a warning this test does not know: {warning!r}")
        parsed.add((match.group("engine"), match.group("reason")))
    return parsed


def check_engines_agree(server_binary: str, monitor_binary: str) -> None:
    """Both must name the same unavailable engines, the same reasons and the same healthy engine."""
    stub = searxng_stub.StubSearXNG(payload=payload(HEALTHY_ENGINE, UNAVAILABLE))
    try:
        result = server_view(server_binary, stub.base_url)
        frame = monitor_view(monitor_binary, stub.base_url, "unavailable:")
        if not stub.requests:
            raise Failure("neither executable asked the instance for anything")
    finally:
        stub.close()

    if result.get("isError"):
        raise Failure(f"the server reported the search failed: {result}")

    structured = cast("dict[str, Any]", result.get("structuredContent") or {})
    warnings = structured.get("warnings")
    if not isinstance(warnings, list):
        raise Failure(f"the server reported no warnings for a stub with two down engines: {result}")
    reported = parse_warnings(cast("list[str]", warnings))
    if reported != set(UNAVAILABLE):
        raise Failure(
            f"the server named {sorted(reported)}, the stub reported {sorted(UNAVAILABLE)}"
        )

    column = "unavailable: " + ", ".join(f"{engine}: {reason}" for engine, reason in UNAVAILABLE)
    if column not in frame:
        raise Failure(f"the dashboard did not draw {column!r}; frame was {frame!r}")
    if HEALTHY_ENGINE not in frame:
        raise Failure(
            f"the dashboard did not name the engine that answered ({HEALTHY_ENGINE}); "
            f"frame was {frame!r}"
        )
    print("  both name duckduckgo: CAPTCHA, mojeek: timeout and the answering engine")


def check_empty_results_agree(server_binary: str, monitor_binary: str) -> None:
    """An instance that answers with nothing must not read as a success on either side."""
    stub = searxng_stub.StubSearXNG(payload=payload(None, ()))
    try:
        result = server_view(server_binary, stub.base_url)
        frame = monitor_view(monitor_binary, stub.base_url, EMPTY_REPORT)
    finally:
        stub.close()

    if not result.get("isError"):
        raise Failure(
            f"the server reported success for an instance that returned nothing: {result}"
        )
    if EMPTY_REPORT not in frame:
        raise Failure(f"the dashboard did not report the empty instance; frame was {frame!r}")
    if "unavailable:" in frame:
        raise Failure(f"the dashboard invented an unavailable engine; frame was {frame!r}")
    print("  both treat an instance that answered with nothing as a failure")


def main() -> int:
    try:
        server_binary, monitor_binary = binaries()
        print(
            "one stub, two executables: "
            f"{os.path.basename(server_binary)} and {os.path.basename(monitor_binary)}"
        )
        check_engines_agree(server_binary, monitor_binary)
        check_empty_results_agree(server_binary, monitor_binary)
    except Failure as error:
        print(f"DUAL CLIENT CONTRACT FAILED: {error}", file=sys.stderr)
        return 1
    except monitor_tty_smoke.Failure as error:
        print(f"DUAL CLIENT CONTRACT FAILED: {error}", file=sys.stderr)
        return 1
    print("DUAL CLIENT CONTRACT PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
