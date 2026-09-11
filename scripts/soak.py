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
import json
import os
import subprocess
import sys
import time
from collections import Counter
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

    def send(self, payload: dict[str, Any]) -> None:
        assert self.process.stdin is not None
        self.process.stdin.write(json.dumps(payload) + "\n")
        self.process.stdin.flush()

    def read(self) -> dict[str, Any] | None:
        assert self.process.stdout is not None
        line = self.process.stdout.readline()
        if not line:
            return None
        try:
            return json.loads(line)
        except json.JSONDecodeError:
            return None

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
        try:
            self.process.stdin.close()
        except Exception:
            pass
        try:
            self.process.wait(timeout=30)
        except subprocess.TimeoutExpired:
            self.process.kill()
        assert self.process.stderr is not None
        return self.process.stderr.read()


def build_environment(providers: set[str]) -> dict[str, str]:
    """Environment with only the requested providers left enabled."""
    environment = dict(os.environ)

    # Anything not explicitly requested is switched off, so the run is unambiguous.
    if "duckduckgo" not in providers and "startpage" not in providers:
        environment["SEARCH_ENABLE_SCRAPERS"] = "false"
    else:
        environment["SEARCH_ENABLE_SCRAPERS"] = "true"
    environment["SEARCH_ENABLE_PARALLEL"] = "true" if "parallel" in providers else "false"

    # Keep the run quiet but retain warnings, which is where provider trouble shows.
    environment.setdefault("SEARCH_LOG_LEVEL", "warning")
    return environment


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", nargs="?", default=None)
    parser.add_argument("--queries", type=int, default=len(QUERIES))
    parser.add_argument("--mode", default="balanced", choices=["fast", "balanced", "thorough"])
    parser.add_argument("--pause", type=float, default=1.0,
                        help="seconds between queries, to imitate real usage")
    parser.add_argument("--providers", default="tavily,duckduckgo,parallel",
                        help="comma-separated providers expected to be active")
    parser.add_argument("--max-results", type=int, default=5)
    args = parser.parse_args()

    if args.binary:
        binary = args.binary
    else:
        try:
            out = subprocess.run(["swift", "build", "-c", "release", "--show-bin-path"],
                                 capture_output=True, text=True, check=True).stdout.strip()
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
    print(f"providers expected: {', '.join(sorted(providers))}\n")

    server = Server(binary, build_environment(providers))
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
        status = server.request(
            "tools/call", {"name": "web_search_status", "arguments": {}}
        )
        initial = {
            p["provider"]: p["status"]
            for p in status["result"]["structuredContent"]["providers"]
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
                text = " ".join(
                    block.get("text", "") for block in payload.get("content", [])
                )
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
                mark = "" if not failed else " ".join(
                    f"{f['provider']}:{f['category']}" for f in failed
                )
                print(
                    f"{index:>3} {elapsed:>6} {count:>2} {','.join(used):<22} "
                    f"{mark:<10} {structured.get('served_from_cache')}"
                )

            if args.pause and index < len(queries):
                time.sleep(args.pause)

        wall = time.time() - started
        status = server.request(
            "tools/call", {"name": "web_search_status", "arguments": {}}
        )
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
            print(f"  latency min/med/max {ordered[0]}ms / "
                  f"{ordered[len(ordered) // 2]}ms / {ordered[-1]}ms")

        print("\n  provider participation (queries each contributed to):")
        for name in sorted(providers):
            print(f"    {name:16} {usage_by_provider.get(name, 0):>3}/{len(queries)}")

        print("\n  provider failures:")
        if not failures_by_provider:
            print("    none")
        for name, count in failures_by_provider.most_common():
            print(f"    {name:16} {count:>3}  (categories: "
                  f"{', '.join(sorted({c for c, _ in failures_by_category.items()}))})")
        if failures_by_category:
            print("    by category: " + ", ".join(
                f"{c}={n}" for c, n in failures_by_category.most_common()
            ))

        print("\n  provider health at end:")
        for provider in final:
            name = provider["provider"]
            if provider["requests"] or provider["status"] not in ("not_configured",):
                print(
                    f"    {name:16} {provider['status']:14} "
                    f"req={provider['requests']:>3} ok={provider['successes']:>3} "
                    f"fail={provider['failures']:>3} "
                    f"last_err={str(provider['last_error'])[:42]}"
                )

        stderr = server.close()
        leaked = [key for key in ("tvly-dev-", "BRAVE_SEARCH_API_KEY=") if key in stderr]
        print(f"\n  credential leak in stderr: {leaked if leaked else 'none'}")

        # A soak that produced errors everywhere, or where the primary provider never
        # contributed, is a failure of the run rather than a result to interpret.
        if errors == len(queries) and queries:
            print("\nSOAK FAILED: every query errored")
            return 1
        print("\nSOAK COMPLETE")
        return 0
    finally:
        if server.process.poll() is None:
            server.process.kill()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\ninterrupted", file=sys.stderr)
        sys.exit(130)
