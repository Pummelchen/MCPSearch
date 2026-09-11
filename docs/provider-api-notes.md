# Provider API Notes — Mojeek, Exa, SearXNG


> These are verification notes gathered while implementing the adapters. Statements marked
> `UNVERIFIED` were not confirmed against a live endpoint or published specification and must not be
> treated as contracts. See `Sources/WebSearchCore/Providers/` for what the code actually relies on.
Compiled from official docs + live endpoint probes. Every claim below is either sourced or marked
`UNVERIFIED`. Probes were run 2026-09-11 against live production endpoints.

---

## PROVIDER 1 — Mojeek Web Search API

### Endpoint / method
- `GET https://api.mojeek.com/search` — used by the official quickstart.
- `GET https://www.mojeek.com/search` — the request-parameters page says endpoints are "appended to
  https://www.mojeek.com". **Both hosts work** (verified live: HTTP 200, `Content-Type:
  application/json; charset=utf-8`).
- `POST` is **not** supported: `POST https://api.mojeek.com/search` returned **HTTP 404** (verified).
- Auth is a **query parameter**, not a header.

### Authentication
- **`api_key` query parameter** is the only documented auth mechanism.
  `https://api.mojeek.com/search?q=mojeek&api_key=YOUR_API_KEY&fmt=json`
- **`X-Mojeek-Api-Key` is NOT a supported auth header.** Verified live:
  - `GET https://api.mojeek.com/search?q=test&fmt=json` (no key) -> **HTTP 403**, `Content-Length: 0`, no body.
  - Same request with `-H "X-Mojeek-Api-Key: INVALID"` -> **HTTP 403**, empty body (identical to no-auth).
  - Same on `www.mojeek.com` with the header -> **HTTP 403**.
  - Same request with `&api_key=INVALID` -> **HTTP 200** + JSON error envelope (see below).
  Conclusion: the header is ignored; Mojeek does **not** authenticate via `X-Mojeek-Api-Key`.
- **`User-Agent`**: no requirement is stated in the official docs. `UNVERIFIED` whether Mojeek
  rejects or throttles default/empty user agents; no `WWW-Authenticate` is returned on 403.

### Request query parameters (official, `/support/api/search/request_parameters.html`)
| Param | Type | Allowed values / default |
|---|---|---|
| `api_key` | string | required; your API key |
| `q` | string | required; URL-encoded query |
| `qm` | string | excluded words |
| `s` | integer | start offset; **`1` = first result**, `11` = first result of page 2 (1-based) |
| `t` | integer | results per page; **default `10`**; plan caps: Startup <=10, Business <=40, Enterprise <=100 |
| `site` | string | limit to a site |
| `since` | string | `'day'|'month'|'year'|YYYYMMDD` |
| `before` | string | same values as `since`; **exclusive** upper bound ("up to, but not including") |
| `rb` / `rbb` | string / int | region boost; `rb` = ISO 3166-1 alpha-2 (`'GB'`); `rbb` 1–100 (recommend 10) |
| `reg` | enum | restrict to UK/DE/FR/EU; doc says use `rb` instead |
| `lb` / `lbb` | string / int | **language boost** (not restriction); `lb` = ISO 639-1 (`'EN'`); `lbb` 1–100 (recommend 100) |
| `lr` | string | **Beta** language *restriction*; ISO 639-1 |
| `clufmt` / `si` | int | clustering; recommend leaving defaults |
| `date` | boolean | `[0|1]`, default `0`; include last-modified date |
| `cdate` | boolean | `[0|1]`, default `0`; include last-crawl date |
| `size` | boolean | `[0|1]`, default `0`; include document size |
| `fmt` | enum | **`[json|xml]`, default `xml`** |
| `datewr` | integer | `[0|100]`, default `0`; rank by date |
| `tlen` | integer | `[0|127]`, default `56`; title length |
| `dlen` | integer | `[0|511]`, default `160`; snippet length |
| `safe` | boolean | **`[0|1]`, default `0`** — this is Mojeek's safesearch param |
| `fi` / `fe` | string | include/exclude domains (comma-separated, max 25, leading dot = subdomains) |
| `categories`, `num_ref_cats`, `num_other_cats`, `facet_date_gap`, `facet_date_limit` | — | **OrgSearch-only** |

Params the question asked about that **do not exist** in Mojeek's documented schema:
- **`arc`** (date filter) — not documented.
- **`until`** — not documented; the date upper bound is **`before`**.
- **`safesearch`** — not documented; Mojeek uses **`safe`**.
- **`l`** — not documented; language is **`lb`** (boost) / **`lr`** (restrict, beta).

### JSON output
- **`fmt=json`** is required; default is XML (`fmt=xml`). Verified live: no `fmt` -> `Content-Type: text/xml`.
- No account-tier gate is documented. The product page advertises "results in JSON or XML format"
  and all plans list "Web Search", so JSON appears available on all plans. `UNVERIFIED` in practice
  (no valid key available).

### Success response shape
Top level is a single `response` object. `results` **is** nested under `response.results`.
```json
{
  "response": {
    "status": "OK",
    "head": {
      "query": "mojeek", "nword": 1,
      "words": [ { "full": "mojeek", "stem": "mojeek", "plus": 1, "hits": 112207 } ],
      "timer": 0.61, "start": 1, "return": 10, "exact": true,
      "results": 112094, "rankm": 169, "dups": 0, "more": 0, "nph": 0
    },
    "cats_ref": { "category1": 100 },
    "cats_other": { "category1": 100 },
    "facet_dates": { "2020-07-01T00:00:00Z": 100 },
    "results": [
      {
        "url": "https://www.mojeek.com/",
        "title": "Mojeek",
        "desc": "Search Settings Site Search Boxes ...",
        "size": "1kb",
        "timestamp": 1184044740,
        "date": "Tue Jul 10 05:19:00 2007",
        "pdate": 1184044740,
        "cdatetimestamp": 1184044740,
        "cdate": "Tue Jul 10 05:19:00 2007",
        "mres": 1,
        "cats": "cat1|cat2|cat3",
        "score": 20.363069534301758,
        "cfs": 5,
        "image": { "url": "https://example.com", "width": 100, "height": 100 }
      }
    ]
  }
}
```
Per-result keys: `url`, `title`, `desc` (**not** `description`), `size`, `timestamp`,
`date` (last-modified, formatted), `pdate` (published timestamp), `cdatetimestamp`, `cdate`,
`mres`, `cats` (OrgSearch only), `score` (float), `cfs` (0–5 confidence, experimental),
`image` (`{url,width,height}`). `size`/`timestamp`/`date`/`cdate` only appear when the matching
flag (`size`/`date`/`cdate`) is requested. There is **no** `last_modified` key; last-modified is
`timestamp`/`date`.

### Pagination
- `s` is a **1-based start offset** (`1` = first result). `t` is page size (default 10).
- No cursor; each page is an independent request. Docs: `head.start` = `start + 1` semantics,
  `head.return` = number returned, `head.results` = total count, `head.exact` = exact vs approximate.

### Error / status codes
Mojeek publishes **no** HTTP error-code page for the Web Search API (only for OrgSearch). Verified live:
- **No `api_key` at all -> HTTP 403**, empty body (`Content-Length: 0`). So yes, **403 is the
  "no/invalid credentials" code for a missing key**.
- **Wrong key supplied via `api_key` -> HTTP 200** with an error *status string in the body*:
  ```json
  {"response":{"status":"Access Denied: invalid key/password","head":{"query":"test","nword":0,
   "rankm":168,"dups":0,"nph":0,"more":0,"timer":0,"start":1,"return":0,"exact":false,"results":0},
   "results":[]}}
  ```
  **Critical for Swift: a bad key can be HTTP 200 — you must branch on `response.status`, not just
  the HTTP status.**
- Documented semantics: `response.status` is `"OK"` or an error message; the docs' example for
  hitting the daily quota is **`"ERROR: Daily Limit Reached"`** (delivered with HTTP 200; the exact
  HTTP code for quota exhaustion is `UNVERIFIED`).
- **Invalid `s` (e.g. `s=abc`) -> HTTP 503**, body `Send search failed` (verified). Bad `safe=5`
  and huge `t` are silently ignored (HTTP 200).
- OrgSearch response-code table (adjacent API, same family): `200 OK`, `201 Created`, `202 Accepted`,
  `400 Bad Request`, **`403 Forbidden` = "API Key doesn't have permissions ... often caused by using
  an incorrect API Key"**, `404 Not Found`, `503 Service Unavailable`.
- **Rate limiting**: the pricing page defines 5/10/custom QPS and 100k/400k/unlimited daily queries.
  The HTTP code emitted when QPS is exceeded is `UNVERIFIED`.

---

## PROVIDER 2 — Exa Search API

Source: OpenAPI 3.1 spec embedded in the docs page (`/docs/reference/search.md`), current `version: 2.0.0`.

### Endpoint / method
- **`POST https://api.exa.ai/search`**, `Content-Type: application/json`. Confirmed as the only
  server (`https://api.exa.ai`) and operation (`post /search`).

### Authentication
- Header **`x-api-key: <key>`** (securityScheme `apiKey`, `in: header`, `name: x-api-key`).
- Alternative: **`Authorization: Bearer <key>`** (securityScheme `bearer`) — explicitly documented
  as supported.
- Verified live:
  - No key -> **HTTP 402** with an x402 payment challenge body (`content-length: 3465`).
  - `x-api-key: INVALID` -> **HTTP 401** `{"requestId":"...","error":"Invalid API key","tag":"INVALID_API_KEY"}`.

### Request body (`SearchRequest`)
Only **`query` is required**.

| Field | Type / allowed values / default |
|---|---|
| `query` | string, minLength 1, **required** |
| `type` | enum **`instant` \| `fast` \| `auto` \| `deep-lite` \| `deep` \| `deep-reasoning`**, **default `auto`**. NOTE: `neural` and `keyword` are **no longer in the enum** (see below) |
| `numResults` | integer 1–100, **default `10`**; `highlights` caps it at 100 |
| `category` | enum **`company` \| `publication` \| `news` \| `personal site` \| `financial report` \| `people`**; other strings accepted as hints |
| `includeDomains` | string[], max 1200; hostname, hostname+path (`example.com/docs`), or wildcard (`*.example.com`) |
| `excludeDomains` | string[], max 1200; same forms |
| `startPublishedDate` | ISO 8601 date-time string, nullable |
| `endPublishedDate` | ISO 8601 date-time string, nullable |
| `startCrawlDate` | **deprecated, no effect, ignored** |
| `endCrawlDate` | **deprecated, no effect, ignored** |
| `moderation` | boolean, default `false` |
| `userLocation` | two-letter ISO country code |
| `additionalQueries` | string[], 1–10; only with a deep-search `type` |
| `compliance` | enum `hipaa` (enterprise) |
| `outputSchema` | `{type: "text"\|"object", ...}`; adds ~2s synthesis latency |
| `systemPrompt` | string |
| `stream` | boolean, default `false`; SSE only used with `outputSchema` |
| `context` | **deprecated**; use `highlights`/`text` |
| `contents` | object — see below |

`category` caveat from the spec: `company` and `people` **only** support a limited filter set;
`startPublishedDate`, `endPublishedDate`, and `excludeDomains` are **not** supported for them and
using them returns **400**.

**`type` values — important correction.** Current enum is `instant`, `fast`, `auto`, `deep-lite`,
`deep`, `deep-reasoning`; default `auto`. `neural` and `keyword` are **not** valid enum values
anymore; the error-codes page's own example message is:
`Expected 'auto' | 'fast' | 'instant' | 'deep-lite' | 'deep' | 'deep-reasoning', received 'slow'`.
The response field `resolvedSearchType` is **deprecated**, "may return an empty string; clients
should not branch on this value" (older responses showed `"resolvedSearchType": "neural"`).
Whether `neural`/`keyword` are still silently accepted for backwards compatibility: `UNVERIFIED`.
Legacy `neural`/`keyword` still appear only as cost sub-fields in `costDollars`.

**Top-level `text` / `includeText` / `highlights` / `includeHighlights` / `summary` /
`includeSummary` / `livecrawl`.** These are **not** properties of the current `SearchRequest`.
The current contract puts all content controls **inside `contents`**. The question's list
(`includeText`, `includeHighlights`, `includeSummary`, plus top-level `text`/`highlights`/`summary`)
is **legacy**; treat as unsupported. Whether they are still silently ignored: `UNVERIFIED`.

### `contents` object (`ContentsOptions`)
```jsonc
"contents": {
  "text": true,                      // or object:
  // "text": { "maxCharacters": 1000, "includeHtmlTags": false,
  //           "verbosity": "compact",  // compact | standard | full (default compact)
  //           "includeSections": ["header","navigation","banner","body","sidebar","footer","metadata"] },
  "highlights": true,                // or object:
  // "highlights": { "query": "Key advancements",
  //                 "verbosity": "low|medium|high",   // BETA: needs `Exa-Beta: dynamic-highlights-2026-08-28`
  //                 "dynamic": true,                   // BETA: same beta header required
  //                 "maxCharacters": 2000,             // 1..10000, incompatible with dynamic
  //                 "numSentences": 1,                 // DEPRECATED (maps to ~1333 chars/sentence)
  //                 "highlightsPerUrl": 1 },           // DEPRECATED / ignored
  "summary": { "query": "Main developments", "schema": { /* JSON Schema */ } },  // object
  "extras": { "links": 1, "imageLinks": 1, "richImageLinks": 1, "richLinks": 1, "codeBlocks": 1 },
  "livecrawl": "never|always|fallback|preferred",   // DEPRECATED
  "livecrawlTimeout": 10000,                         // ms, 1..90000, default 10000
  "maxAgeHours": 24,                                 // -1..720
  "subpages": 1,                                     // 0..100, default 0
  "subpageTarget": "sources"                         // string | string[]
}
```
- `text`: **boolean or object** with `maxCharacters` (1–10000), `includeHtmlTags` (default `false`),
  `verbosity` (`compact|standard|full`, default `compact`), `includeSections` (best-effort).
- `highlights`: **boolean or object** with `query` / `maxCharacters` / beta `verbosity`+`dynamic`,
  plus deprecated `numSentences` + `highlightsPerUrl`. `highlightScores` in the response are cosine
  similarity scores.
- `summary`: **object only** in the current schema (`query`, `schema`). `summary: true` (boolean)
  is not in the schema — `UNVERIFIED` whether accepted.
- `maxAgeHours` semantics, verbatim: **`0` fetches fresh content** and is "the supported way to apply
  text rendering options to newly fetched pages"; positive = use cache if younger than N hours;
  `-1` = always use cache; omitted = fallback fetch when cache is unavailable. Range `-1..720`.
  So yes, **`maxAgeHours: 0` means live/fresh crawl**; `livecrawl` is the deprecated equivalent and
  **must not be sent together with `maxAgeHours`**.

### Success response
`SearchResponse` is a `oneOf` of `SearchResultsResponse` (normal) and `SearchSynthesisResponse`
(when `outputSchema` is used). Normal shape:
```json
{
  "requestId": "b5947044c4b78efa9552a7c89b306d95",
  "results": [
    {
      "title": "A Comprehensive Overview of Large Language Models",
      "url": "https://arxiv.org/pdf/2307.06435.pdf",
      "publishedDate": "2023-11-16T01:36:32.547Z",
      "author": "Humza Naveed, ...",
      "id": "https://arxiv.org/abs/2307.06435",
      "image": "https://arxiv.org/pdf/2307.06435.pdf/page_1.png",
      "favicon": "https://arxiv.org/favicon.ico",
      "text": "Abstract Large Language Models (LLMs) ...",
      "highlights": ["Such requirements have limited their adoption..."],
      "highlightScores": [0.4600165784358978],
      "summary": "This overview paper on Large Language Models ...",
      "subpages": [ { "title": "...", "url": "...", "publishedDate": "...", "author": "...", "id": "...", "image": "...", "favicon": "..." } ],
      "entities": [ /* company | person | publication entity objects */ ],
      "extras": { "links": [], "imageLinks": [], "richImageLinks": [], "richLinks": [], "codeBlocks": [] }
    }
  ],
  "resolvedSearchType": "",           // DEPRECATED; may be empty
  "costDollars": { "total": 0.007, "search": { "neural": 0.007, "keyword": 0.0 }, "contents": { "text": 0, "highlights": 0, "summary": 0 } },
  "searchTime": 312.4,
  "output": { }                        // required by schema; synthesis payload
}
```
- Required top-level: **`results`** and **`output`**. `requestId` is present in examples but **is not
  in the required list**.
- `SearchResultOutput` required: **`title`, `url`** only, `additionalProperties: false`.
  Per-result keys: `title`, `url`, `publishedDate`, `author` (nullable), `id`, `image`, `favicon`,
  `text`, `highlights` (string[]), `highlightScores` (number[]), `summary`, `subpages`, `entities`,
  `extras`.
- **There is no `score` field in the current per-result schema.** Older Exa responses included
  `score`; it is absent from the current OpenAPI `SearchResultOutput`. Do not rely on it.
- `publishedDate` is `type: string, format: date-time`; the description says "Format is YYYY-MM-DD"
  but the example is full ISO-8601 (`2023-11-16T01:36:32.547Z`) — parse defensively.
- Response headers: `x-request-id`, `x-exa-queued` (`true`/`false`), `x-exa-queue-ms`.

### Error response + status codes
Envelope: `{ "requestId": string, "error": string, "tag": string }` (all three required).
```json
{"requestId":"60a99b1acb27bbe3c538a6dd5011f2bc","error":"Invalid API key","tag":"INVALID_API_KEY"}
```
- **`400`** — `INVALID_REQUEST_BODY`, `INVALID_REQUEST`, `INVALID_REQUEST_QUERY`, `INVALID_URLS`,
  `INVALID_NUM_RESULTS`, `INVALID_FLAGS`, `INVALID_JSON_SCHEMA`, `NUM_RESULTS_EXCEEDED`, `NO_CONTENT_FOUND`.
- **`401`** — `INVALID_API_KEY` (missing/empty/invalid key). Verified live.
- **`402`** — `NO_MORE_CREDITS`, `API_KEY_BUDGET_EXCEEDED`, `TEAM_BUDGET_EXCEEDED`. **Also returned
  when no API key is supplied at all** (x402 payment challenge, verified live); the challenge body
  extends the envelope with `x402Version`, `resource`, `accepts` (and optional `extensions`).
- **`403`** — `ACCESS_DENIED` (`/search` only), `FEATURE_DISABLED`, `CONTENT_FILTER_ERROR`.
- **`422`** — `FETCH_DOCUMENT_ERROR`.
- **`429`** — rate limit. **Different body shape:** `{"error": "..."}` only (no `requestId`/`tag`),
  though the OpenAPI lists tag `RATE_LIMIT_EXCEEDED`. Default `/search` limit: **10 QPS**.
- **`500`** — `DEFAULT_ERROR`, `INTERNAL_ERROR`; `501` `UNABLE_TO_GENERATE_RESPONSE` (`/answer`);
  `502`/`503` upstream/unavailable.
- Error tags are open-ended: treat unknown tags as a generic error of the HTTP status.
- Retry signal: `Retry-After` is exposed (see `access-control-expose-headers`).

---

## PROVIDER 3 — SearXNG Search API

Source: official search API docs, `settings_defaults.py`, shipped `settings.yml`, `webapp.py`,
`webutils.py`, `webadapter.py`, `_base.py`, `limiter.py` on `master` (version string
`2026.9.11+61d660276`).

### Endpoint / method
- **`GET /`**, **`GET /search`**, **`POST /`**, **`POST /search`**.
- `GET` -> URL query params; `POST` -> `application/x-www-form-urlencoded` form data.
- Example: `curl 'https://searx.example.org/search?q=searxng&format=json'`

### Parameters
| Param | Values / default |
|---|---|
| `q` | **required**; engine syntax supported |
| `categories` | comma-separated category list |
| `engines` | comma-separated engine names |
| `language` | code; default from `search.default_lang` (or browser detection) |
| `pageno` | **default `1`**; must be a positive integer |
| `time_range` | docs list **`day`, `month`, `year`**; the code accepts **`day`, `week`, `month`, `year`** (see note) |
| `format` | `json`, `csv`, `rss` (and `html`); must be enabled in `search.formats` |
| `safesearch` | **`0` = None, `1` = Moderate, `2` = Strict**; default from `search.safe_search` |
| `theme` | `simple` (instance-dependent) |

**`time_range` discrepancy (verified in code):** `searx/webadapter.py::parse_time_range` accepts
`(None, 'day', 'week', 'month', 'year')` and raises `SearxParameterException` otherwise. The docs
enumerate only `day`, `month`, `year`, so **`week` is valid in code but undocumented**.

### `format` values and the JSON-disabled-by-default reality
- Canonical set (`searx/settings_defaults.py`): **`OUTPUT_FORMATS = ['html', 'csv', 'json', 'rss']`**.
- **Shipped `settings.yml` ships `search.formats: [html]` only** — the line is literally:
  ```yaml
  # formats: [html, csv, json, rss]
  formats:
    - html
  ```
  So **JSON is disabled by default** on a stock instance. (Note the subtlety: `settings_defaults.py`
  declares the *schema* default as all four, but the shipped config file pins it to `[html]`.)
- Operator enables it under `search:` in `settings.yml`, e.g.:
  ```yaml
  search:
    formats: [html, json]      # or [html, csv, json, rss]
  ```
- Docs wording: "Supported formats are defined in settings.yml ... **Requesting an unset format
  will return a 403 Forbidden error.** Be aware that many public instances have these formats disabled."

### Response when `format=json` is disabled
- **HTTP 403**, enforced by `flask.abort(403)` in `searx/webapp.py`:
  ```python
  output_format = sxng_request.form.get('format', 'html')
  if output_format not in OUTPUT_FORMATS:
      output_format = 'html'
  if output_format not in settings['search']['formats']:
      flask.abort(403)
  ```
- The body is Flask/Werkzeug's **default HTML 403 page** (no custom 403 error handler exists in
  `webapp.py`; only `404` has one), i.e. **HTML, not JSON**, roughly
  `<h1>Forbidden</h1><p>You don't have permission to access this resource.</p>`.
  `UNVERIFIED`: the exact byte-for-byte body on a vanilla instance (public instances I probed front
  the app with WAF/bot protection).
- Note the ordering above: an **unknown** `format` value is silently coerced to `html` first
  (so `format=bogus` renders HTML, it does not 403); only a *known but disabled* format (e.g. `json`)
  hits the 403.
- **This 403 is the documented status code for "format not allowed."** There is no separate,
  distinct status code for that case.

### Other status codes
- **`400`** with a JSON body when `q` is missing and a non-HTML format was requested:
  `{"error": "No query"}`.
- **`400`** with `{"error": "<message>"}` for `SearxParameterException` (bad `pageno`, `safesearch`,
  `time_range`, `language`).
- **`500`** with `{"error": "search error"}` on internal failure.
- **`429`** — yes, SearXNG returns **HTTP 429**. Two sources in `searx/limiter.py`:
  - block-list hit: `flask.make_response(('IP is on BLOCKLIST - %s' % msg, 429))`;
  - `botdetection.ip_limit` on `/search` (enabled via `server.limiter: true` + Valkey, or
    `server.public_instance: true`, which forces `link_token = true`).
  Empirically confirmed on multiple public instances (`searx.tiekoetter.com`, `search.hbubli.cc`,
  `opnxng.com`, `paulgo.io`, `searx.perennialte.ch`, `priv.au` all returned 429). Public instances
  also commonly front the app with a CAPTCHA/JS challenge (HTTP 200 HTML "Verifying your browser…")
  rather than 429. `Retry-After` presence: `UNVERIFIED`.

### Success JSON shape
Built by `searx/webutils.py::get_json_response` (single source of truth):
```python
data = {
    'query': sq.query,
    'results': [_.as_dict() for _ in rc.get_ordered_results()],
    'answers': [_.as_dict() for _ in rc.answers],
    'corrections': list(rc.corrections),
    'infoboxes': rc.infoboxes,
    'suggestions': list(rc.suggestions),
    'unresponsive_engines': get_translated_errors(rc.unresponsive_engines),
}
```
- **`number_of_results` is NOT present in current master.** It is absent from `webutils.py`,
  `results.py`, `webapp.py`, and `search/models.py` (grep: 0 matches). It existed in older
  SearXNG/searx releases. Do not depend on it.
- `unresponsive_engines` is a **sorted list of `[engine_name, translated_error_message]` pairs**
  (2-element arrays), e.g. `[["google", "timeout"]]`; engine errors include `timeout`,
  `parsing error`, `CAPTCHA`, `too many requests`, `access denied`, `server API error`,
  `HTTP error`, `network error`, and may be prefixed `"Suspended: "`.
- `corrections` and `suggestions` are arrays of strings; `answers` is an array of answer objects;
  `infoboxes` is an array of infobox objects.

Example:
```json
{
  "query": "searxng",
  "results": [
    {
      "url": "https://docs.searxng.org/",
      "title": "SearXNG Documentation",
      "content": "SearXNG is a free internet metasearch engine...",
      "publishedDate": "2024-01-15T00:00:00",
      "engine": "duckduckgo",
      "engines": ["duckduckgo", "brave"],
      "score": 3.5,
      "category": "general",
      "positions": [1, 2]
    }
  ],
  "answers": [],
  "corrections": [],
  "infoboxes": [],
  "suggestions": [],
  "unresponsive_engines": [["google", "timeout"]]
}
```

### Per-result keys
`as_dict()` on `MainResult` returns every `msgspec` struct field (inherited `Result` fields first):
`url`, `engine`, `parsed_url`, `template`, `title`, `content`, `img_src`, `iframe_src`, `audio_src`,
`thumbnail`, `publishedDate`, `pubdate`, `length`, `views`, `author`, `metadata`, `priority`,
`engines`, `open_group`, `close_group`, `positions`, `score`, `category`.

Serialization details (from `JSONEncoder` in `webutils.py` + field types in `_base.py`):
- **`publishedDate` is nullable** — type is `datetime | None`, default `None`; emitted as `null`
  when absent. When set, it is serialized via `datetime.isoformat()`
  (e.g. `"2024-01-15T00:00:00"`, with offset when the engine supplied one). `pubdate` is the
  **deprecated** string form (`'%Y-%m-%d %H:%M:%S%z'`).
- **`engines` is a `set[str]`** in Python -> serialized as a JSON **array** (order not guaranteed).
- `positions` -> array of ints; `score` -> float; `category` -> string; `engine` -> string.
- `length` is a `timedelta | None` -> serialized as **float seconds** (`total_seconds()`), or `null`.
- `parsed_url` is a `urllib.parse.ParseResult` (a tuple subclass) -> serialized as a JSON **array**.
- `open_group` / `close_group` are internal grouping booleans that leak into the JSON.
- Results may also be legacy dict-shaped (`LegacyResult.as_dict()` returns the dict itself), so an
  instance/engine mix can produce slightly varying key sets. Parse defensively.

---

## Explicitly UNVERIFIED / could not confirm

**Mojeek**
- Whether `fmt=json` is gated behind a specific paid tier (docs imply not; no key to test).
- HTTP status code when the **daily query limit** is reached (docs only define a `response.status`
  string `"ERROR: Daily Limit Reached"`; observed auth errors use HTTP 200) — exact code UNVERIFIED.
- HTTP status code when the **QPS** limit is exceeded — UNVERIFIED.
- Whether the `response.head` key for clustering-excluded docs is literally `more`, `excluded`, or
  `more|excluded` (docs are garbled; live error response showed `"more":0` and `"nph":0`).
- Existence of `arc`, `l`, `safesearch`, `until`, and header auth (`X-Mojeek-Api-Key`) — none are
  documented, and the header was **empirically rejected** (403, same as no auth).
- Any `User-Agent` requirement — not documented, not tested with a valid key.

**Exa**
- Whether legacy values `type: "neural"` / `"keyword"` are still silently accepted.
- Whether legacy top-level `text`, `highlights`, `summary`, `includeText`, `includeHighlights`,
  `includeSummary` are ignored or rejected (not in the current schema).
- Whether `summary: true` (boolean) is accepted (schema documents an object only).
- Whether `score` is ever emitted (absent from `SearchResultOutput`).
- The `x402` challenge body was observed (402) but its full field contents were not enumerated.
- Exact rate-limit windows/bursts beyond the documented 10 QPS for `/search`.

**SearXNG**
- Exact 403 response body on a vanilla instance (source proves `flask.abort(403)` => Werkzeug HTML
  default page; I could not hit a non-WAF, non-rate-limited public instance that had `json` disabled).
- Whether some instances add a custom JSON error handler for 403.
- Whether `Retry-After` is set on 429.
- Whether `number_of_results` still appears on older SearXNG releases (it is absent from current
  `master`).

---

## Sources
- Mojeek: [Web Search API product page](https://www.mojeek.com/services/search/web-search-api/) ·
  [Search API Quickstart](https://www.mojeek.com/support/api/search/quickstart.html) ·
  [Request Parameters](https://www.mojeek.com/support/api/search/request_parameters.html) ·
  [JSON Response Format](https://www.mojeek.com/support/api/search/json_response.html) ·
  [OrgSe Response Codes](https://www.mojeek.com/support/api/orgse/response_codes.html)
- Exa: [Search API reference](https://exa.ai/docs/reference/search) ·
  [Error Codes](https://exa.ai/docs/reference/error-codes) ·
  [Rate Limits](https://exa.ai/docs/reference/rate-limits)
- SearXNG: [Search API](https://docs.searxng.org/dev/search_api.html) ·
  [`search:` settings](https://docs.searxng.org/admin/settings/settings_search.html) ·
  [Main Results / result types](https://docs.searxng.org/dev/result_types/main/mainresult.html) ·
  source on `master`: [`webapp.py`](https://raw.githubusercontent.com/searxng/searxng/master/searx/webapp.py) ·
  [`webutils.py`](https://raw.githubusercontent.com/searxng/searxng/master/searx/webutils.py) ·
  [`webadapter.py`](https://raw.githubusercontent.com/searxng/searxng/master/searx/webadapter.py) ·
  [`limiter.py`](https://raw.githubusercontent.com/searxng/searxng/master/searx/limiter.py) ·
  [`result_types/_base.py`](https://raw.githubusercontent.com/searxng/searxng/master/searx/result_types/_base.py) ·
  [`settings_defaults.py`](https://raw.githubusercontent.com/searxng/searxng/master/searx/settings_defaults.py) ·
  [`settings.yml`](https://raw.githubusercontent.com/searxng/searxng/master/searx/settings.yml)
