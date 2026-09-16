#!/usr/bin/env python3
"""Health check for a SearXNG instance used as an MCP search provider.

Verifies the three things that actually break in practice, in the order they break:

1. **The instance answers at all** - wrong URL, not running, or bound elsewhere.
2. **JSON output is enabled.** The stock image serves only `html`, so `format=json`
   returns HTTP 403. This is the single most common reason a self-hosted SearXNG
   "does not work" with an MCP server, and the error is easy to misread.
3. **Which engines actually contribute.** SearXNG degrades silently: an engine can be
   CAPTCHA-blocked or erroring while the instance still returns results from the
   others, so the absence of an index is invisible unless it is checked.

Usage:
    python3 scripts/searxng_health.py [base-url] [--query TEXT] [--json]

Exit codes: 0 healthy, 1 the instance or its JSON API is unusable, 2 unreachable.
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter
from typing import Any, cast


def probe(base_url: str, query: str, timeout: float = 25.0):
    """Return (http_status, payload_or_text)."""
    url = f"{base_url.rstrip('/')}/search?{urllib.parse.urlencode({'q': query, 'format': 'json'})}"
    # `base_url` comes from the command line, and `urlopen` supports `file://`: assert the
    # scheme and host before opening anything.
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        raise ValueError(f"refusing to probe a non-HTTP URL: {base_url!r}")
    request = urllib.request.Request(url, headers={"Accept": "application/json"})
    try:
        # nosemgrep: dynamic-urllib-use-detected
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = response.read().decode("utf-8", "replace")
            try:
                return response.status, json.loads(body)
            except json.JSONDecodeError:
                return response.status, body
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode("utf-8", "replace")[:400]
    except (urllib.error.URLError, ConnectionError, OSError) as error:
        return None, str(error)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("base_url", nargs="?", default="http://127.0.0.1:8888")
    parser.add_argument("--query", default="swift concurrency")
    parser.add_argument("--json", action="store_true", help="emit machine-readable output")
    args = parser.parse_args()

    try:
        status, payload = probe(args.base_url, args.query)
    except ValueError as error:
        # A refused URL is a usage error, so report it as one instead of a traceback.
        if args.json:
            print(json.dumps({"healthy": False, "reason": "invalid_url", "detail": str(error)}))
        else:
            print(f"INVALID URL  {error}")
        return 2

    if status is None:
        if args.json:
            print(json.dumps({"healthy": False, "reason": "unreachable", "detail": payload}))
        else:
            print(f"UNREACHABLE  {args.base_url}\n  {payload}")
            print("  Is the instance running?  docker compose -f deploy/docker-compose.yml up -d")
        return 2

    if status == 403:
        if args.json:
            print(json.dumps({"healthy": False, "reason": "json_disabled", "status": status}))
        else:
            print(f"JSON DISABLED  {args.base_url} returned HTTP 403")
            print("  The instance is running but `format=json` is not permitted.")
            print("  Add `json` under `search.formats` in settings.yml and restart:")
            print("    search:")
            print("      formats:")
            print("        - html")
            print("        - json")
        return 1

    if status != 200 or not isinstance(payload, dict):
        if args.json:
            print(
                json.dumps(
                    {
                        "healthy": False,
                        "reason": "unexpected_response",
                        "status": status,
                        "detail": str(payload)[:200],
                    }
                )
            )
        else:
            print(f"UNEXPECTED RESPONSE  HTTP {status}")
            print(f"  {str(payload)[:300]}")
        return 1

    # The guard above proved this is a JSON object; the cast is what tells the type checker.
    payload_obj = cast("dict[str, Any]", payload)
    results = cast("list[Any]", payload_obj.get("results") or [])
    engines: Counter[str] = Counter()
    for result in results:
        for engine in result.get("engines") or [result.get("engine")]:
            if engine:
                engines[engine] += 1
    unresponsive = cast("list[Any]", payload_obj.get("unresponsive_engines") or [])

    healthy = bool(results)

    if args.json:
        print(
            json.dumps(
                {
                    "healthy": healthy,
                    "base_url": args.base_url,
                    "result_count": len(results),
                    "engines": dict(engines.most_common()),
                    "unresponsive_engines": unresponsive,
                },
                indent=2,
            )
        )
        return 0 if healthy else 1

    print(f"instance   {args.base_url}   HTTP {status}, JSON enabled")
    print(f"query      {args.query!r}")
    print(f"results    {len(results)}")
    if engines:
        print(
            "engines    " + ", ".join(f"{name} ({count})" for name, count in engines.most_common())
        )
    else:
        print("engines    none contributed")
    if unresponsive:
        print("unavailable:")
        for entry in unresponsive:
            if isinstance(entry, list):
                pair = cast("list[Any]", entry)
                if len(pair) >= 2:
                    print(f"  - {pair[0]}: {pair[1]}")
    else:
        print("unavailable: none reported")

    if not healthy:
        print("\nUNHEALTHY: the instance answered but returned no results.")
        return 1

    print("\nHEALTHY")
    return 0


if __name__ == "__main__":
    sys.exit(main())
