#!/usr/bin/env python3
"""Volume soak test for SwiftWebSearchMCP.

Runs a list of realistic queries through the **real server binary** over stdio and
reports per-query and aggregate behaviour, so provider rate limits and degradation
show up before real traffic finds them.

What it is looking for:

- how each provider behaves as a metered allowance or anonymous rate limit is
  consumed over a sustained run, which a single-query test cannot reveal;
- whether one provider's quota exhaustion degrades the search or breaks it;
- latency drift and failure categories as the run progresses.

Usage:
    python3 scripts/soak.py [--queries N] [--mode fast|balanced|thorough] \\
                            [--pause SECONDS] [--providers csv] [path-to-binary]

Credentials come from the environment (or a git-ignored config.env). Providers whose
credentials are absent are simply reported as unconfigured.
"""

from __future__ import annotations

import argparse
import contextlib
import json
import os
import queue
import subprocess
import sys
import threading
import time
from collections import Counter, defaultdict
from typing import Any

# 50 queries spread across the kinds of work a coding agent actually does: library
# and API lookups, error diagnosis, conceptual "why" questions, release/version
# questions, and comparisons. Mixing these matters because a provider that is strong
# on keyword lookups can be weak on interpretive questions, and the reverse.
QUERIES: list[str] = [
    # API / library lookup
    "Swift 6.3 concurrency changes",
    "URLSession async await timeout configuration",
    "SwiftUI onAppear vs task modifier",
    "Python asyncio task group exception handling",
    "Rust tokio select! macro cancelled branch",
    "Go context cancellation propagation http client",
    "TypeScript satisfies operator vs as const",
    "Postgres partial index where clause syntax",
    "nginx proxy_pass websocket upgrade headers",
    "docker compose healthcheck depends_on condition",
    # error diagnosis
    "kubernetes pod evicted memory pressure fix",
    "postgres deadlock detected while updating table",
    "swift compiler error sendable closure captures",
    "rust borrow checker cannot move out of borrowed content",
    "python ModuleNotFoundError despite pip install",
    "nginx 502 bad gateway upstream timed out",
    "git detached head after rebase recover",
    "xcode linker error duplicate symbol arm64",
    "docker permission denied var run docker sock",
    "terraform state lock error already locked",
    # conceptual / interpretive
    "why unix failed the top 500 list",
    "why is TCP slow start still used",
    "why did Google abandon SPDY for HTTP/2",
    "why do databases use B-trees instead of hash indexes",
    "why is Rust ownership considered hard",
    "why did XML lose to JSON in web APIs",
    "why are monoliths coming back",
    "why is observability harder than monitoring",
    # release / version questions
    "Swift 6.3 release notes",
    "Python 3.13 free-threading status",
    "PostgreSQL 18 new features",
    "Rust 2024 edition breaking changes",
    "Node.js 24 release schedule",
    "Kubernetes 1.32 release notes",
    "Ubuntu 26.04 LTS features",
    # comparisons
    "tokio vs async-std performance 2026",
    "sqlite vs duckdb analytics workload",
    "gRPC vs REST internal microservices",
    "opentelemetry vs prometheus for traces",
    "vector database comparison pgvector qdrant",
    # operations / practices
    "kubernetes cost optimisation right-sizing",
    "postgres index bloat vacuum best practice",
    "zero downtime database migration patterns",
    "secrets management kubernetes external secrets",
    "incident postmortem blameless template",
    # protocol / spec
    "MCP protocol spec transports 2025",
    "Model Context Protocol tools list schema",
    "OAuth 2.1 PKCE required changes",
    "WebTransport vs WebSocket browser support",
    "HTTP/3 QUIC deployment lessons learned",
    "JSON Schema 2020-12 additionalProperties semantics",
]


# Every provider the server can register. A `--providers` request is enforced by
# disabling everything else explicitly: any provider with ambient credentials would
# otherwise stay active while the header printed a different expected set.
ALL_PROVIDERS = (
    "tavily",
    "brave",
    "mojeek",
    "exa",
    "searxng",
    "open_web_search",
    "duckduckgo",
    "startpage",
    "parallel",
)

# Credential variables whose values and shapes must never reach the server's
# diagnostics.
SECRET_VARIABLES = (
    "TAVILY_API_KEY",
    "BRAVE_SEARCH_API_KEY",
    "MOJEEK_API_KEY",
    "EXA_API_KEY",
    "JINA_API_KEY",
    "DEEPSEEK_API_KEY",
)

# Substrings that indicate credential material regardless of the exact value. The
# original scan looked for only two hard-coded strings; a leak of any other provider's
# key (or a key read from `config.env`) went unnoticed.
LEAK_MARKERS = (
    "tvly-",
    "Bearer ",
    "X-Subscription-Token",
    "x-api-key",
    "api_key=",
    "BRAVE_SEARCH_API_KEY=",
    "MOJEEK_API_KEY=",
    "EXA_API_KEY=",
    "JINA_API_KEY=",
    "DEEPSEEK_API_KEY=",
)


class Server:
    """A running server driven over stdio with newline-delimited JSON-RPC."""

    def __init__(self, binary: str, environment: dict[str, str]) -> None:
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
        # Drain both pipes on daemon threads rather than reading them where they are used.
        #
        # stderr: the pipe holds about 16 KiB, `SEARCH_LOG_LEVEL=warning` is set on purpose, and
        # fifty queries against rate-limited providers emit warnings. The child filled the pipe,
        # blocked in `write`, stopped answering stdout, and the parent blocked in `readline` — a
        # deadlock rather than a timeout, with no verdict at all (ledger A0019). Reading stderr only
        # in `close`, after `wait`, could never have drained it in time.
        #
        # stdout: a blocking `readline` has no timeout of its own, so a server that stopped
        # answering without closing the stream hung the whole run (ledger A0018). A reader thread
        # turns the wait into a queue get with a deadline, which the timeout below can report.
        self._stderr_chunks: list[str] = []
        self._stderr_lock = threading.Lock()
        threading.Thread(target=self._drain_stderr, daemon=True).start()
        self._stdout: queue.Queue[str | None] = queue.Queue()
        threading.Thread(target=self._drain_stdout, daemon=True).start()

    def _drain_stderr(self) -> None:
        stream = self.process.stderr
        if stream is None:
            return
        for line in stream:
            with self._stderr_lock:
                self._stderr_chunks.append(line)

    def _stderr_text(self) -> str:
        with self._stderr_lock:
            return "".join(self._stderr_chunks)

    def _drain_stdout(self) -> None:
        stream = self.process.stdout
        if stream is not None:
            for line in stream:
                self._stdout.put(line)
        # End of stream, so a reader blocked on `get` wakes and reports a closed stdout rather than
        # waiting out its deadline.
        self._stdout.put(None)

    def send(self, payload: dict[str, Any]) -> None:
        assert self.process.stdin is not None
        self.process.stdin.write(json.dumps(payload) + "\n")
        self.process.stdin.flush()

    def read(self, timeout: float = 120.0) -> dict[str, Any] | None:
        """Next protocol message, or None only when stdout is at end of stream.

        Raises when the server does not answer within `timeout`: a read that never returned used to
        hang the whole run with no verdict, because the class's only timeout was on `wait` in
        `close`, which is unreachable while a read is blocked (ledger A0018).
        """
        try:
            line = self._stdout.get(timeout=timeout)
        except queue.Empty:
            raise RuntimeError(
                f"the server did not answer within {timeout:.0f}s; abandoning the run rather than "
                "hanging, which produced no verdict at all"
            ) from None
        if line is None:
            return None
        try:
            return json.loads(line)
        except json.JSONDecodeError as error:
            # A line that is not JSON is a corrupted protocol stream, not end of stream:
            # returning None here let `request` discard the offending line and report a
            # closed stdout instead.
            raise RuntimeError(
                f"stdout is not valid JSON (protocol stream corrupted): {error}; "
                f"offending line: {line!r}"
            ) from error

    def request(self, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        self._next_id += 1
        request_id = self._next_id
        payload: dict[str, Any] = {"jsonrpc": "2.0", "id": request_id, "method": method}
        if params is not None:
            payload["params"] = params
        self.send(payload)
        while True:
            message = self.read()
            if message is None:
                raise RuntimeError("server closed stdout")
            if message.get("id") == request_id:
                return message

    def notify(self, method: str) -> None:
        self.send({"jsonrpc": "2.0", "method": method})

    def close(self) -> str:
        assert self.process.stdin is not None
        # The child may already have closed its end; closing a pipe then raises OSError or
        # ValueError, and there is nothing to recover.
        with contextlib.suppress(OSError, ValueError):
            self.process.stdin.close()
        try:
            self.process.wait(timeout=30)
        except subprocess.TimeoutExpired:
            self.process.kill()
        # The drain thread appends whatever arrived; reading the pipe here would return nothing,
        # because the thread owns it (ledger A0019).
        return self._stderr_text()


def silent_providers(providers: set[str], usage: dict[str, int]) -> list[str]:
    """Requested providers that contributed to no query at all."""
    return sorted(name for name in providers if usage.get(name, 0) == 0)


def run_verdict(
    queries: int, errors: int, providers: set[str], usage: dict[str, int]
) -> str | None:
    """Why the run must be reported as a failure, or None when it is a result to interpret.

    A soak that errored on every query, or where a requested provider never contributed, says
    something other than what its header claims. The second half of that sentence used to be only
    a comment. Kept separate from `main` so the CI guard can drive every case without
    running a soak.
    """
    if queries and errors == queries:
        return "every query errored"
    silent = silent_providers(providers, usage)
    if silent:
        return "requested provider(s) contributed to no query: " + ", ".join(silent)
    return None


def build_environment(providers: set[str]) -> dict[str, str]:
    """Environment with only the requested providers left enabled.

    ``--providers`` is authoritative: everything not requested is switched off via
    ``SEARCH_DISABLED_PROVIDERS``. Without this, an ambient ``TAVILY_API_KEY`` (or any
    other configured provider) stayed active while the run header claimed it was
    excluded, so the reported expected set did not describe the run.
    """
    environment = dict(os.environ)

    # Anything not explicitly requested is switched off, so the run is unambiguous. The value is
    # *assigned* from the request, never merged with the ambient one: merging kept a requested
    # provider disabled when the environment already named it, and with every provider requested
    # the old `if disabled:` guard left the ambient list untouched — both contradicting the run
    # header, which is what `--providers` is supposed to describe.
    disabled = sorted(set(ALL_PROVIDERS) - providers)
    environment["SEARCH_DISABLED_PROVIDERS"] = ",".join(disabled)

    # Scrapers and Parallel are also opt-in flags, not just registry entries.
    environment["SEARCH_ENABLE_SCRAPERS"] = (
        "true" if providers & {"duckduckgo", "startpage"} else "false"
    )
    environment["SEARCH_ENABLE_PARALLEL"] = "true" if "parallel" in providers else "false"

    # Keep the run quiet but retain warnings, which is where provider trouble shows.
    environment.setdefault("SEARCH_LOG_LEVEL", "warning")
    return environment


def parse_dotenv(contents: str) -> dict[str, str]:
    """Minimal ``KEY=VALUE`` parser, mirroring the server's own ``config.env`` handling."""
    result: dict[str, str] = {}
    for raw_line in contents.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        line = line.removeprefix("export ")
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        if key and value:
            result[key] = value
    return result


def load_secret_values() -> dict[str, str]:
    """Credential name -> value, from the environment and any config file the server reads.

    The server resolves credentials from the environment and from ``SEARCH_CONFIG_FILE``,
    so both are scanned; the repository-root ``config.env`` is included as a fallback so
    a key that only lives there is still checked for leaks.
    """
    values: dict[str, str] = {}
    for name in SECRET_VARIABLES:
        value = os.environ.get(name, "").strip()
        if value:
            values[name] = value

    candidates: list[str] = []
    configured = os.environ.get("SEARCH_CONFIG_FILE", "").strip()
    if configured:
        candidates.append(configured)
    repository_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    candidates.append(os.path.join(repository_root, "config.env"))

    for path in candidates:
        try:
            with open(path, encoding="utf-8") as handle:
                parsed = parse_dotenv(handle.read())
        except OSError:
            continue
        for name in SECRET_VARIABLES:
            value = parsed.get(name, "").strip()
            if value:
                values.setdefault(name, value)
    return values


def find_credential_leaks(text: str, secrets: dict[str, str]) -> list[str]:
    """Names and markers describing any credential material present in ``text``."""
    found = {marker for marker in LEAK_MARKERS if marker in text}
    for name, value in secrets.items():
        # Short values produce false positives; real keys are far longer than this.
        if len(value) >= 8 and value in text:
            found.add(f"{name} value")
    return sorted(found)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", nargs="?", default=None)
    parser.add_argument("--queries", type=int, default=len(QUERIES))
    parser.add_argument("--mode", default="balanced", choices=["fast", "balanced", "thorough"])
    parser.add_argument(
        "--pause", type=float, default=1.0, help="seconds between queries, to imitate real usage"
    )
    parser.add_argument(
        "--providers",
        default="tavily,duckduckgo,parallel",
        help="comma-separated providers to run; every other provider "
        "is explicitly disabled so the run matches this set",
    )
    parser.add_argument("--max-results", type=int, default=5)
    args = parser.parse_args()

    # `QUERIES[: args.queries]` with a negative count silently takes queries from the end,
    # so `--queries -3` ran 48 of 51 while the header presented that as the request; a zero
    # count starts nothing. Reject both before the run rather than run a different soak than
    # the one asked for.
    if args.queries <= 0:
        parser.error("--queries must be positive")

    if args.binary:
        binary = args.binary
    else:
        try:
            out = subprocess.run(
                ["swift", "build", "-c", "release", "--show-bin-path"],
                capture_output=True,
                text=True,
                check=True,
            ).stdout.strip()
        except subprocess.CalledProcessError as error:
            print(f"could not determine build path: {error}", file=sys.stderr)
            return 2
        binary = os.path.join(out, "SwiftWebSearchMCP")

    if not os.path.isfile(binary):
        print(f"binary not found: {binary}", file=sys.stderr)
        return 2

    providers = {p.strip() for p in args.providers.split(",") if p.strip()}
    queries = QUERIES[: args.queries]

    print(f"soak: {len(queries)} queries, mode={args.mode}, pause={args.pause}s")
    print(f"binary: {binary}")
    print(f"providers expected: {', '.join(sorted(providers))}")
    disabled = sorted(set(ALL_PROVIDERS) - providers)
    if disabled:
        # Printed so the header describes the run that actually happens: unlisted
        # providers are switched off in build_environment, not merely unmentioned.
        print(f"providers disabled: {', '.join(disabled)}")
    print()

    server = Server(binary, build_environment(providers))
    # Text the *server* supplied that this report prints. The leak scan read only stderr, but
    # the report prints `last_error`, which `ProviderHealth` fills from a failure message — and
    # the HTTP client here documents that a URL in a diagnostic is a credential in a
    # diagnostic, because Mojeek authenticates with `api_key=` in the query string. A
    # credential could reach the report and never be checked (ledger A0020).
    server_diagnostics: list[str] = []
    try:
        server.request(
            "initialize",
            {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "soak", "version": "1.0.0"},
            },
        )
        server.notify("notifications/initialized")

        # Baseline: what the server thinks is usable before any traffic.
        status = server.request("tools/call", {"name": "web_search_status", "arguments": {}})
        initial = {
            p["provider"]: p["status"] for p in status["result"]["structuredContent"]["providers"]
        }
        print("provider status at start:")
        for name, state in sorted(initial.items()):
            print(f"  {name:16} {state}")
        print()

        print(f"{'#':>3} {'ms':>6} {'n':>2} {'sources':<22} {'failed':<10} cache")
        print("-" * 78)

        latencies: list[int] = []
        failures_by_provider: Counter[str] = Counter()
        failures_by_category: Counter[str] = Counter()
        # Per provider as well as overall: printing the global counter on every provider's line
        # attributed every category in the run to every provider that failed at all.
        categories_by_provider: defaultdict[str, Counter[str]] = defaultdict(Counter)
        usage_by_provider: Counter[str] = Counter()
        errors = 0
        results_total = 0
        started = time.time()

        for index, query in enumerate(queries, start=1):
            began = time.time()
            response = server.request(
                "tools/call",
                {
                    "name": "web_search",
                    "arguments": {
                        "query": query,
                        "max_results": args.max_results,
                        "mode": args.mode,
                    },
                },
            )
            elapsed = int((time.time() - began) * 1000)
            latencies.append(elapsed)

            payload = response.get("result", {})
            if payload.get("isError"):
                errors += 1
                text = " ".join(block.get("text", "") for block in payload.get("content", []))
                print(f"{index:>3} {elapsed:>6}  ERROR  {text[:60]}")
            else:
                structured = payload.get("structuredContent", {})
                used = structured.get("providers_used", [])
                failed = structured.get("providers_failed", [])
                count = len(structured.get("results", []))
                results_total += count
                for name in used:
                    usage_by_provider[name] += 1
                for failure in failed:
                    failures_by_provider[failure["provider"]] += 1
                    failures_by_category[failure["category"]] += 1
                    categories_by_provider[failure["provider"]][failure["category"]] += 1
                mark = (
                    ""
                    if not failed
                    else " ".join(f"{f['provider']}:{f['category']}" for f in failed)
                )
                print(
                    f"{index:>3} {elapsed:>6} {count:>2} {','.join(used):<22} "
                    f"{mark:<10} {structured.get('served_from_cache')}"
                )

            if args.pause and index < len(queries):
                time.sleep(args.pause)

        wall = time.time() - started
        status = server.request("tools/call", {"name": "web_search_status", "arguments": {}})
        final = status["result"]["structuredContent"]["providers"]

        print("\n" + "=" * 78)
        print("SUMMARY")
        print("=" * 78)
        print(f"  queries            {len(queries)}")
        print(f"  hard errors        {errors}")
        print(f"  results returned   {results_total}")
        print(f"  wall time          {wall:.1f}s  ({wall / max(1, len(queries)):.2f}s/query)")
        if latencies:
            ordered = sorted(latencies)
            print(
                f"  latency min/med/max {ordered[0]}ms / "
                f"{ordered[len(ordered) // 2]}ms / {ordered[-1]}ms"
            )

        print("\n  provider participation (queries each contributed to):")
        for name in sorted(providers):
            print(f"    {name:16} {usage_by_provider.get(name, 0):>3}/{len(queries)}")

        print("\n  provider failures:")
        if not failures_by_provider:
            print("    none")
        for name, count in failures_by_provider.most_common():
            print(
                f"    {name:16} {count:>3}  (categories: "
                f"{', '.join(sorted(categories_by_provider[name]))})"
            )
        if failures_by_category:
            print(
                "    by category: "
                + ", ".join(f"{c}={n}" for c, n in failures_by_category.most_common())
            )

        print("\n  provider health at end:")
        for provider in final:
            name = provider["provider"]
            # Kept untruncated for the scan: a credential can straddle the 42-character display cut,
            # and a partial match would be missed.
            server_diagnostics.append(str(provider.get("last_error") or ""))
            if provider["requests"] or provider["status"] != "not_configured":
                print(
                    f"    {name:16} {provider['status']:14} "
                    f"req={provider['requests']:>3} ok={provider['successes']:>3} "
                    f"fail={provider['failures']:>3} "
                    f"last_err={str(provider['last_error'])[:42]}"
                )

        stderr = server.close()
        leaked = find_credential_leaks(
            stderr + "\n" + "\n".join(server_diagnostics), load_secret_values()
        )
        print(f"\n  credential leak in the server's output: {leaked or 'none'}")

        if leaked:
            # A credential in a diagnostic is a defect, not an observation to interpret.
            print(f"\nSOAK FAILED: credential material appeared in the server's output: {leaked}")
            return 1

        # A soak that produced errors everywhere, or where a requested provider never
        # contributed, is a failure of the run rather than a result to interpret.
        verdict = run_verdict(len(queries), errors, providers, usage_by_provider)
        if verdict:
            print(f"\nSOAK FAILED: {verdict}")
            return 1
        print("\nSOAK COMPLETE")
        return 0
    finally:
        if server.process.poll() is None:
            server.process.kill()
        # The scan must not be skippable. It sat inside the try above, so any exception before
        # it — the status call raising, or a shape change making the payload index fail —
        # jumped straight here, and this block only killed the child: the stderr that may hold
        # the leak was never read or scanned, so the check silently did not run on exactly the
        # failed runs (ledger A0020). The run is failing anyway; this makes the leak visible
        # instead of silent.
        stderr_tail = server.close()
        leaked_late = find_credential_leaks(
            stderr_tail + "\n" + "\n".join(server_diagnostics), load_secret_values()
        )
        if leaked_late:
            print(
                f"\nSOAK FAILED: credential material appeared in the server's output: {leaked_late}"
            )


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\ninterrupted", file=sys.stderr)
        sys.exit(130)
