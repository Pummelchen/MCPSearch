#!/usr/bin/env python3
"""Drive the mcps-mon interactive display through a pseudo-terminal.

The dashboard's key handling, colour and cursor control only run when stdin and stdout
are a terminal, so a pipe cannot reach them. A PTY is a kernel object with no GUI
involved: allocating one opens no window and touches no desktop, which means the
interactive path can be exercised — and asserted on — from a script, locally and in CI.

What it checks:

  1. startup hides the cursor and clears the screen, as a full-screen display must;
  2. each frame homes the cursor and clears to the end of the line and screen, so a
     shorter frame cannot leave the previous one's tail on screen;
  3. colour is on by default and ``c`` turns it off without disturbing the layout;
  4. ``e`` hides the per-node engine breakdown and shows it again;
  5. ``r`` refreshes immediately instead of waiting out the interval;
  6. ``p`` probes providers now, and a reachable instance turns from ready to OK;
  7. ``q`` exits cleanly, restores the cursor, clears to the end of the screen and
     prints the final summary.

A SearXNG-shaped stub is served on loopback, so the run is hermetic: no vendor key, no
external network, no credits. Provider variables are scrubbed from the child's
environment for the same reason.

Usage:
    python3 scripts/monitor_tty_smoke.py [path-to-mcps-mon]

With no argument the binary is located via ``swift build -c release --show-bin-path``.
"""

from __future__ import annotations

import errno
import fcntl
import http.server
import json
import os
import pty
import re
import select
import struct
import subprocess
import sys
import termios
import threading
import time
from typing import Any

# Escape sequences the display is expected to emit. Kept in step with
# Sources/WebSearchCore/Monitor/Terminal.swift.
HIDE_CURSOR = "\x1b[?25l"
SHOW_CURSOR = "\x1b[?25h"
CLEAR_SCREEN = "\x1b[2J"
CLEAR_TO_END_OF_LINE = "\x1b[K"
CLEAR_TO_END_OF_SCREEN = "\x1b[J"
# Terminal.home() is move(row: 1, column: 1), which NIO-free terminals accept and which
# is what the renderer emits; "[H" is the short form it does *not* use.
CURSOR_HOME = "\x1b[1;1H"

# How much to read from the PTY at once. A small value reproduces a slow consumer, which
# is what a loaded CI runner is: it guarantees the transcript ends mid-frame and proves the
# assertions only ever look at complete ones. Override with MONITOR_SMOKE_READ_CHUNK.
READ_CHUNK = int(os.environ.get("MONITOR_SMOKE_READ_CHUNK", "65536"))

# An SGR sequence: the colour attributes the renderer wraps text in.
SGR = re.compile(r"\x1b\[[0-9;]*m")
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")

# Provider credentials and toggles must not leak in: an ambient key would make the probe
# spend real credits, which is exactly what this test must never do.
SCRUBBED_VARIABLES = (
    "TAVILY_API_KEY",
    "BRAVE_SEARCH_API_KEY",
    "MOJEEK_API_KEY",
    "EXA_API_KEY",
    "JINA_API_KEY",
    "OPEN_WEB_SEARCH_URL",
    "PARALLEL_MCP_URL",
    "DEEPSEEK_API_KEY",
    "SEARCH_ENABLE_SCRAPERS",
    "SEARCH_ENABLE_PARALLEL",
    "SEARCH_CONFIG_FILE",
    "SEARCH_PROVIDER_ORDER",
    "SEARCH_DISABLED_PROVIDERS",
)

COLUMNS, ROWS = 120, 40


class Failure(Exception):
    """A smoke-test assertion failed."""


def locate_binary() -> str:
    if len(sys.argv) > 1:
        return sys.argv[1]
    try:
        path = subprocess.run(
            ["swift", "build", "-c", "release", "--show-bin-path"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError) as error:
        raise Failure(f"could not locate the binary: {error}") from error
    return os.path.join(path, "mcps-mon")


class StubSearXNG:
    """A SearXNG-shaped JSON endpoint, on loopback only."""

    def __init__(self) -> None:
        payload = json.dumps(
            {
                "query": "swift concurrency",
                "results": [
                    {
                        "title": "Stub result",
                        "url": "https://example.com/stub",
                        "content": "A stub result for the monitor smoke test.",
                        "engine": "brave",
                        "engines": ["brave"],
                    }
                ],
                "unresponsive_engines": [["duckduckgo", "HTTP connection error"]],
            }
        ).encode()
        handler = self._handler(payload)
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    @staticmethod
    def _handler(payload: bytes) -> type[http.server.BaseHTTPRequestHandler]:
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self) -> None:  # noqa: N802 (stdlib naming)
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, *args: Any) -> None:
                """Keep the stub quiet: its chatter would corrupt our transcript."""

        return Handler

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    def stop(self) -> None:
        self.server.shutdown()
        self.server.server_close()


def complete_frames(transcript: str) -> list[str]:
    """The frames whose closing clear-to-end-of-screen has arrived.

    Reads from a PTY are chunked, so the tail of the transcript can be half a frame. A fast
    machine delivers a whole frame per read and a loaded CI runner does not, which is exactly
    how an assertion can pass locally and fail in CI: it was inspecting a frame whose node
    section had not been written yet.
    """
    return [
        piece
        for piece in transcript.split(CURSOR_HOME)[1:]
        if CLEAR_TO_END_OF_SCREEN in piece
    ]


class Session:
    """A monitor process attached to a pseudo-terminal."""

    def __init__(self, binary: str, base_url: str) -> None:
        self.master, slave = pty.openpty()
        # A known window size: the renderer lays out to whatever it is told, and a PTY
        # without a size would silently fall back to the same default anyway.
        fcntl.ioctl(
            self.master,
            termios.TIOCSWINSZ,
            struct.pack("HHHH", ROWS, COLUMNS, 0, 0),
        )

        environment = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "SEARXNG_BASE_URL": base_url,
            "SEARCH_LOG_LEVEL": "warning",
        }
        # Prove the scrub rather than assume it.
        for name in SCRUBBED_VARIABLES:
            if name in os.environ:
                environment.pop(name, None)

        self.transcript = ""
        self.process = subprocess.Popen(
            [binary, "--node", f"stub={base_url}", "--interval", "1"],
            stdin=slave,
            stdout=slave,
            stderr=slave,
            env=environment,
            start_new_session=True,
            close_fds=True,
        )
        os.close(slave)
        os.set_blocking(self.master, False)

    def drain(self, seconds: float) -> str:
        """Read whatever arrives within `seconds`, appending to the transcript."""
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            ready, _, _ = select.select([self.master], [], [], 0.05)
            if not ready:
                continue
            try:
                chunk = os.read(self.master, READ_CHUNK)
            except OSError as error:
                if error.errno in (errno.EIO, errno.EBADF):
                    break
                raise
            if not chunk:
                break
            self.transcript += chunk.decode("utf-8", "replace")
        return self.transcript

    def send(self, key: str) -> None:
        os.write(self.master, key.encode())

    def frames(self) -> list[str]:
        """Complete frames painted so far, one entry per cursor-home repaint."""
        return complete_frames(self.transcript)

    def frame_text(self) -> str:
        """The most recent frame with the escape sequences stripped."""
        frames = self.frames()
        if not frames:
            raise Failure("no frame was painted")
        return ANSI.sub("", frames[-1])

    def wait_for(self, predicate, description: str, timeout: float = 12.0) -> None:
        """Read frames until the predicate holds, or fail with the description."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.drain(0.4)
            if predicate(self):
                return
        raise Failure(f"timed out waiting for {description}")

    def close(self) -> None:
        try:
            self.process.terminate()
        except ProcessLookupError:
            pass
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
        os.close(self.master)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise Failure(message)


def run(binary: str) -> None:
    stub = StubSearXNG()
    session = Session(binary, stub.url)
    try:
        # 1. A full-screen display hides the cursor and clears the screen on start.
        session.drain(3.0)
        start = session.transcript
        require(HIDE_CURSOR in start, "the display must hide the cursor on startup")
        require(CLEAR_SCREEN in start, "the display must clear the screen on startup")

        # 2. A frame homes the cursor and clears to the end of each line and the screen.
        session.wait_for(lambda s: len(s.frames()) >= 1, "the first frame")
        frame = session.frames()[-1]
        require(CURSOR_HOME in session.transcript, "each frame must home the cursor")
        require(
            CLEAR_TO_END_OF_LINE in frame,
            "each painted line must clear to the end of the line",
        )
        require(
            CLEAR_TO_END_OF_SCREEN in frame,
            "each frame must clear to the end of the screen",
        )

        text = session.frame_text()
        for expected in ("MCPSearch Monitor", "PROVIDERS", "SEARXNG NODES", "quit"):
            require(expected in text, f"the frame is missing {expected!r}")

        # 3. Colour is on for a terminal; `c` turns it off and keeps the layout.
        session.wait_for(
            lambda s: SGR.search(s.frames()[-1]) is not None,
            "colour in the frame",
        )
        session.send("c")
        session.wait_for(
            lambda s: SGR.search(s.frames()[-1]) is None,
            "colour to be switched off",
        )
        plain = session.frame_text()
        require("PROVIDERS" in plain, "toggling colour must not disturb the layout")

        # 4. `e` hides the per-node engine breakdown, column header included, and shows it
        # again. The footer legend also says "engines", so the check must look at the data
        # and at the node header, not at the word itself.
        def engine_column(text: str) -> bool:
            """Whether the node table is showing its engine column."""
            for line in text.splitlines():
                if line.strip().startswith("node") and line.rstrip().endswith("engines"):
                    return True
            return False

        session.wait_for(
            lambda s: "unavailable:" in s.frame_text() and engine_column(s.frame_text()),
            "the engine breakdown in the node rows and header",
        )
        plain = session.frame_text()
        session.send("e")
        session.wait_for(
            lambda s: not engine_column(s.frame_text())
            and "unavailable:" not in s.frame_text(),
            "the engine breakdown to be hidden, header included",
        )
        session.send("e")
        session.wait_for(
            lambda s: engine_column(s.frame_text()) and "unavailable:" in s.frame_text(),
            "the engine breakdown to come back",
        )

        # 5. `r` repaints at once rather than waiting out the interval. The interval here
        # is one second, so the check is that a new frame arrives well inside it.
        before = len(session.frames())
        started = time.monotonic()
        session.send("r")
        session.wait_for(lambda s: len(s.frames()) > before, "a refresh", timeout=5.0)
        require(
            time.monotonic() - started < 0.9,
            "`r` should repaint immediately, not on the next tick",
        )

        # 6. `p` probes providers now; the stub answers, so SearXNG goes to OK. The first
        # frame already probes once, so this asserts the key path rather than the probe.
        session.send("p")
        session.wait_for(
            lambda s: "OK" in s.frame_text(),
            "a successful provider probe after pressing p",
            timeout=20.0,
        )

        # 7. `q` exits cleanly and leaves the terminal usable.
        session.send("q")
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and session.process.poll() is None:
            session.drain(0.2)
        exit_code = session.process.poll()
        require(exit_code == 0, f"`q` should exit 0, got {exit_code}")

        session.drain(1.5)
        tail = session.transcript
        require(SHOW_CURSOR in tail, "the display must restore the cursor on exit")
        require(
            CLEAR_TO_END_OF_SCREEN in tail,
            "the display must clear to the end of the screen on exit",
        )
        require("final:" in ANSI.sub("", tail), "the run should end with its summary")

        print(f"  startup hid the cursor and cleared the screen")
        print(f"  frames home the cursor and clear to the end of the line and screen")
        print(f"  colour on by default; `c` switched it off ({len(session.frames())} frames painted)")
        print(f"  `e` hid and restored the engine breakdown")
        print(f"  `r` repainted immediately")
        print(f"  `p` probed providers and the stub answered OK")
        print(f"  `q` exited 0, restored the cursor and printed the summary")
    finally:
        session.close()
        stub.stop()


def main() -> int:
    binary = locate_binary()
    if not os.path.exists(binary):
        print(f"monitor-tty smoke FAILED: no binary at {binary}", file=sys.stderr)
        return 2

    print(f"smoke-testing the interactive display of {binary}")
    try:
        run(binary)
    except Failure as error:
        print(f"MONITOR TTY SMOKE FAILED: {error}", file=sys.stderr)
        return 1
    except Exception as error:  # pragma: no cover - surfaced rather than swallowed
        print(f"MONITOR TTY SMOKE ERRORED: {error!r}", file=sys.stderr)
        return 1

    print("MONITOR TTY SMOKE PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
