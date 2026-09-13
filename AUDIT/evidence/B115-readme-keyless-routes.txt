# B115 — the README undercounted the keyless routes and mis-stated two `Needs` cells

Host: node1 (arm64, macOS 26.6.2) · branch audit/2026-09-13

## What was wrong

The heading said four routes need no vendor key, and the selection rule behind that number was
never stated — so it could not be checked, and it was not the rule the code implements:

```
$ sed -n '120p' README.md      # before
No account is required to run this. Four of the routes below need no vendor key at all:
```

The registration predicates say five, not four. The five adapters that require no vendor
credential:

```
$ grep -n 'var isConfigured' Sources/WebSearchCore/Providers/*.swift
Sources/WebSearchCore/Providers/DuckDuckGoProvider.swift:52:    public var isConfigured: Bool { scrapersEnabled }
Sources/WebSearchCore/Providers/OpenWebSearchProvider.swift:51:    public var isConfigured: Bool { true }
Sources/WebSearchCore/Providers/ParallelMCPProvider.swift:63:    public nonisolated var isConfigured: Bool { enabled }
Sources/WebSearchCore/Providers/SearXNGProvider.swift:43:    public var isConfigured: Bool { true }
Sources/WebSearchCore/Providers/StartpageProvider.swift:49:    public var isConfigured: Bool { scrapersEnabled }
```

`isConfigured == true` is not the whole story — registration is gated separately:
`SearchPipelineFactory.swift:103-115` registers SearXNG only when `SEARXNG_BASE_URL` is set, and
`:117-128` registers Open Web Search only when `OPEN_WEB_SEARCH_URL` is set, while
`ParallelMCPProvider`/the scrapers are gated on their flags. So the routes split as:

| needs | routes |
| --- | --- |
| an endpoint you supply, no vendor key | SearXNG (`SEARXNG_BASE_URL`), Open Web Search (`OPEN_WEB_SEARCH_URL`) |
| a flag only | Parallel, DuckDuckGo, Startpage |

Five in total. The README's four excluded Open Web Search — but included SearXNG, which needs an
endpoint for exactly the same reason, so the rule the count encoded did not hold. An Open Web
Search entry even said so in its own row ("Aggregation endpoint"), three rows below a claim that
implied it did not belong in the keyless group.

Two `Needs` cells were also wrong or incomplete independently of the count:

* `Self-hosted SearXNG` said `Docker only`, but `SEARXNG_BASE_URL` is equally required.
* `Startpage` said `none`, while `StartpageProvider.swift:49` returns `scrapersEnabled` — the
  adapter is registered but inert until `SEARCH_ENABLE_SCRAPERS=true`. Only the DuckDuckGo row
  mentioned the flag, so the two opt-in scrapers read inconsistently.

## The fix

The count is now five and the rule behind it is stated in the sentence, so it can be checked
against the code rather than inferred. `SEARXNG_BASE_URL` is added to the SearXNG row, Open Web
Search's row says explicitly that it needs no vendor key, and Startpage carries
`SEARCH_ENABLE_SCRAPERS=true` like DuckDuckGo. Parallel's flag moved from the Notes column into
`Needs`, because that column is what a reader scans to find out how to turn a route on.

## Verification

The claim is code-derived and was re-checked against the predicates above, not against the wiki.
Markdown only: no Swift, Python, shell or YAML changed, so the suite and the formatters are
unaffected — this change is documentation, and the CI run in the record proves the workspace is
still green rather than proving anything about this file.
