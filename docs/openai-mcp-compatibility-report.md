# OpenAI API ⇄ MCP Server Compatibility — Requirements, Breakages, and Safe Schema Subset

Audience: author of a **Swift MCP server** that must work with OpenAI clients.
Legend: **VERIFIED** = official OpenAI documentation / official OpenAI repo / OpenAI-generated SDK types.
**UNVERIFIED** = third-party report (GitHub issue/PR, forum) with exact text quoted.
**NOT FOUND** = no evidence located.

Primary official sources used:
- MCP & Connectors guide — https://developers.openai.com/api/docs/guides/tools-connectors-mcp
- Function calling guide — https://developers.openai.com/api/docs/guides/function-calling
- Structured Outputs guide (incl. "Supported schemas") — https://developers.openai.com/api/docs/guides/structured-outputs
- Responses create reference — https://developers.openai.com/api/reference/resources/responses/methods/create
- Responses object reference — https://developers.openai.com/api/reference/resources/responses
- Chat Completions reference — https://developers.openai.com/api/reference/resources/chat
- Agents API MCP connections — https://developers.openai.com/api/docs/guides/agents-api/tools/mcp
- Secure MCP Tunnel — https://developers.openai.com/api/docs/guides/secure-mcp-tunnels
- Building MCP servers — https://developers.openai.com/api/docs/mcp
- Plugin MCP server reference — https://developers.openai.com/plugins/reference

---

## 1. Responses API remote MCP support

### 1.1 Exact `type: "mcp"` tool fields — VERIFIED

From the API reference (`Mcp object { server_label, type, allowed_callers, 9 more }`):

| Field | Type | Required | Notes |
|---|---|---|---|
| `type` | `"mcp"` | yes | |
| `server_label` | `string` | yes | "A label for this MCP server, used to identify it in tool calls." |
| `server_url` | `string` | one of `server_url` / `connector_id` / `tunnel_id` | Remote MCP URL |
| `connector_id` | enum | one of the three | `connector_dropbox`, `connector_gmail`, `connector_googlecalendar`, `connector_googledrive`, `connector_microsoftteams`, `connector_outlookcalendar`, `connector_outlookemail`, `connector_sharepoint` |
| `tunnel_id` | `string` | one of the three | Secure MCP Tunnel ID |
| `server_description` | `string` | no | Context for the model |
| `authorization` | `string` | no | OAuth access token. **Not stored**; must be re-sent on every request |
| `headers` | `map[string] or null` | no | "Optional HTTP headers to send to the MCP server. Use for authentication or other purposes." |
| `allowed_tools` | `array of string` **or** `object { read_only, tool_names }` `or null` | no | Filter object: `tool_names: string[]`, `read_only: boolean` |
| `require_approval` | `"always"` \| `"never"` \| `object { always, never }` \| `null` | no | Filter form: `always`/`never` each `{ read_only, tool_names }` |
| `defer_loading` | `boolean` | no | Requires tool search (`gpt-5.4`+); model sees only label+description until loaded |
| `allowed_callers` | `array of "direct" \| "programmatic"` `or null` | no | Tool invocation context |

`read_only` matching: "If an MCP server is annotated with `readOnlyHint` … it will match this filter" — `readOnlyHint` is the MCP spec 2025-06-18 `ToolAnnotations` field.

**Default approval behavior — VERIFIED:** "the MCP tool in the Responses API defaults to requiring approvals of each MCP tool call being made." Setting `require_approval: "never"` is the opt-out.

### 1.2 Transports and protocol versions

- **Streamable HTTP and HTTP/SSE — VERIFIED.** "The Responses API works with remote MCP servers that support either the Streamable HTTP or the HTTP/SSE transport protocols." The ChatGPT developer-mode docs likewise state "Supported MCP protocols: SSE and streaming HTTP."
- **stdio directly — VERIFIED NOT SUPPORTED by the Responses API MCP tool.** The tool accepts only `server_url` / `connector_id` / `tunnel_id`, and the guide scopes it to "any server on the public Internet." There is no `command`/`args`/transport object on the Responses MCP tool.
- **stdio indirectly — VERIFIED.** Two supported bridges:
  1. **Secure MCP Tunnel**: pass `tunnel_id`. `tunnel-client` runs inside your network and, per the docs, needs "An MCP server that `tunnel-client` can reach over **stdio or HTTP** from inside your network." Explicitly: "Pass the tunnel identifier as `tunnel_id`… Do not pass the OpenAI-hosted tunnel endpoint as `server_url`." Supports ChatGPT, Codex, and the Responses API. **Not** for public plugin distribution.
  2. **Agents API** (different product): a real stdio transport exists — `{"type": "stdio", "command": ..., "args": [...], "cwd": "/abs/path"}`, "runs a process in your session's environment"; `command` and an absolute `cwd` are required. This is Agents API sessions/executors, **not** the Responses API hosted MCP tool.
- **Exact protocol revision negotiated — UNVERIFIED for the Responses API hosted client.** No official page states a supported `protocolVersion` list for it. Indirect official signals: the MCP guide links MCP spec **2025-03-26** for tool error handling and **2025-06-18** for `readOnlyHint`; the plugins docs link **2025-06-18** for tool descriptors and **2025-11-25** for `ToolAnnotations`/authorization. Separately, **VERIFIED via the `openai/codex` repo (PR #20562)**: OpenAI's own Codex MCP client "currently negotiates MCP `2025-06-18`", with 2025-11-25 as future work. Practical consequence for a Swift server: implement `initialize` version negotiation and accept at minimum 2025-06-18 (and 2025-03-26); do not hard-require 2025-11-25.

### 1.3 `tools/list` discovery and filtering — VERIFIED

- Discovery is automatic and server-driven: "When you specify a remote MCP server in the `tools` parameter, the API will attempt to get a list of tools from the server."
- Success produces an `mcp_list_tools` output item. Its `tools[]` entries contain **exactly** `input_schema` (`unknown`), `name` (`string`), `annotations` (`optional unknown or null`), `description` (`optional string or null`). The item also has `id`, `server_label`, `type`, `error?`.
- Caching: "As long as the `mcp_list_tools` item is present in the context of an API request, the API will not fetch a list of tools from the MCP server again at each turn." Keeping it in context is the recommended latency optimization.
- Filtering: "you can use the `allowed_tools` parameter to only import those tools." Two forms — a plain string array of tool names, or the `McpToolFilter` object (`tool_names`, and `read_only` matched against the server's `readOnlyHint` annotation, spec 2025-06-18).
- Failure surfaces on the item: `mcp_list_tools.error` and, in Realtime, `mcp_list_tools.failed`.
- Tool-call results are an `mcp_call` item: `arguments` (`string`, JSON-encoded), `name`, `server_label`, `output` (`string or null`), `error` (`mcp_protocol_error` | `mcp_tool_execution_error` | `http_error`), `status` (`in_progress`|`completed`|`incomplete`|`calling`|`failed`), `approval_request_id`.

### 1.4 `outputSchema` / `structuredContent` — VERIFIED: NOT surfaced

- `mcp_list_tools.tools[]` has **no** `output_schema` / `outputSchema` field. (Contrast: the Responses **function** tool does have an optional `output_schema` — "A JSON Schema describing the JSON value encoded in string outputs for this function tool" — but the MCP tool does not.)
- `mcp_call.output` is typed **`string or null`**. There is no `structuredContent` / `structured_content` field anywhere in `mcp_call`. Tool results are flattened to a string.
- Official guidance for server authors confirms the practical implication — declare `outputSchema` **and** duplicate the object into the text content array: "In MCP, return this object as `structuredContent` and include the same value as a JSON-encoded string in the content array **for compatibility**." Example given:
  ```json
  { "structuredContent": { "results": [...] },
    "content": [ { "type": "text", "text": "{\"results\":[...]}" } ] }
  ```
- **Actionable:** a Swift MCP server should emit **both** `structuredContent` and a JSON-encoded `content[0].text`. Never rely on `structuredContent` alone for an OpenAI client. Declaring `outputSchema` is good practice (and required for ChatGPT app/plugin review) but OpenAI's Responses MCP client will not use it.

---

## 2. Chat Completions function calling (the "older API" path)

### 2.1 Converting MCP tool definitions → Chat Completions `tools` — VERIFIED

An MCP `tools/list` entry `{ name, description, inputSchema }` maps directly, with no wrapper on the schema:

```json
{
  "type": "function",
  "function": {
    "name": "<mcp tool name, sanitized>",
    "description": "<mcp description>",
    "parameters": { "<the MCP inputSchema, normalized>" },
    "strict": true
  }
}
```

Verified from the Chat Completions reference (`ChatCompletionFunctionTool object { function, type }` → `FunctionDefinition`):
- `type`: "The type of the tool. Currently, only `function` is supported."
- `function.name`: required — "Must be a-z, A-Z, 0-9, or contain underscores and dashes, with a maximum length of 64."
- `function.description`: optional — "A description of what the function does, used by the model to choose when and how to call the function."
- `function.parameters`: optional — "The parameters the functions accepts, described as a JSON Schema object." and "Omitting `parameters` defines a function with an empty parameter list."
- `function.strict`: optional `boolean or null` — "If set to true, the model will follow the exact schema defined in the `parameters` field. Only a subset of JSON Schema is supported when `strict` is `true`."

**`strict` default differs by API — VERIFIED:** "If you omit `strict`, the default depends on the API: **Responses** requests will attempt to normalize your schema into strict mode when possible, and will fall back to non-strict, best-effort function calling if the schema cannot be made compatible… When fallback happens, the response tool will show `strict: false`. **Chat Completions requests remain non-strict by default.**" To force non-strict in Responses, set `strict: false` explicitly.

### 2.2 JSON Schema feature status — VERIFIED from "Supported schemas"

**Supported types:** `String`, `Number`, `Boolean`, `Integer`, `Object`, `Array`, `Enum`, `anyOf`.

**Supported constraints:**
- `string`: `pattern`; `format` — allowlist is exactly `date-time`, `time`, `date`, `duration`, `email`, `hostname`, `ipv4`, `ipv6`, `uuid`
- `number`: `multipleOf`, `maximum`, `exclusiveMaximum`, `minimum`, `exclusiveMinimum`
- `array`: `minItems`, `maxItems`
- `$defs` / `$ref` / definitions and recursion: supported ("$defs must be defined under the schema param")

**Not supported (VERIFIED):**
- Composition: `allOf`, `not`, `dependentRequired`, `dependentSchemas`, `if`, `then`, `else`. **`oneOf` appears nowhere in the docs** as supported (zero occurrences in the combined API docs export) — use `anyOf`.
- Objects: `unevaluatedProperties`, `propertyNames`, `minProperties`, `maxProperties`
- Arrays: `unevaluatedItems`, `contains`, `minContains`, `maxContains`, `uniqueItems`
- Root must be an object and must not be `anyOf`.
- For **fine-tuned** models only, additionally: strings `minLength`, `maxLength`, `pattern`, `format`; numbers `minimum`, `maximum`, `multipleOf`; objects `patternProperties`; arrays `minItems`, `maxItems`.

**Hard limits (VERIFIED):** up to **5000 object properties** total and **10 levels of nesting**; total string length of all property names, definition names, enum values and const values ≤ **120,000** characters; up to **1000 enum values** across all enum properties; a single string enum with >250 values must total ≤ **15,000** characters.

### 2.3 Direct answers to the requested keyword statuses

| Keyword | Status | Evidence |
|---|---|---|
| `additionalProperties: false` | **REQUIRED under strict**, not forbidden. "Structured Outputs only supports generating specified keys / values, so we require developers to set `additionalProperties: false` to opt into Structured Outputs." Strict-mode requirement #1: "`additionalProperties` must be set to `false` for each object in the `parameters`." In **non-strict** Chat Completions it is optional; on the Responses path it is reported as required regardless (see §3). | Structured Outputs §"additionalProperties: false must always be set in objects"; Function calling §"Strict mode" |
| `default` | **Not a supported keyword**; not rejected by `api.openai.com` in an OpenAI maintainer's test, but **rejected by Azure OpenAI**. See §3.4 for the exact error. Strip it for portability. | openai-agents-python #4390 (maintainer `seratch` comment) |
| `minimum` / `maximum` | **SUPPORTED** (with `exclusiveMinimum` / `exclusiveMaximum` / `multipleOf`). Officially exercised in a `strict: true` example. Not supported on fine-tuned models. | Structured Outputs §"Number Restrictions" |
| `maxItems` | **SUPPORTED** (with `minItems`). Not supported on fine-tuned models. | Structured Outputs §"Supported array properties" |
| `"type": ["string", "null"]` | **SUPPORTED, including under `strict: true`.** This is the *documented* way to emulate an optional parameter. Both the function-calling "Strict mode enabled" example and the Structured Outputs examples use `"type": ["string","null"]` together with `"strict": true` and `"required": ["location","units"]`. See §3.5 for the one real failure mode. | Function calling §"Strict mode"; Structured Outputs §"All fields must be `required`" |
| `format: "uri"` | **REJECTED — not in the allowlist.** Exact 400 in §3.1. | Structured Outputs §"Supported `string` properties"; Roo-Code #10198 |
| `enum` | **SUPPORTED.** Limits: ≤1000 enum values total; >250 values in one string enum → ≤15,000 chars total. `enum` at the **root** is rejected. | Structured Outputs §"Limitations on enum size" |

**Optional-vs-required rule — VERIFIED:** "All fields in `properties` must be marked as `required`." and "Although all fields must be required (and the model will return a value for each parameter), it is possible to emulate an optional parameter by using a union type with `null`." Required-set membership is **mandatory** under strict; a genuinely-optional property is expressed by making it `required` while allowing `null`.

**Rejection on violation — VERIFIED:** "If you send `strict: true` and your schema does not meet the requirements above, the request will be rejected with details about the missing constraints." Also: "If you turn on Structured Outputs by supplying `strict: true` and call the API with an unsupported JSON Schema, you will receive an error."

### 2.4 Name / description / tool-count limits

- **Function `name`: max 64 chars — VERIFIED.** "Must be a-z, A-Z, 0-9, or contain underscores and dashes, with a maximum length of 64." (Same wording for `response_format.json_schema.name`.)
- **`description`: NO documented maximum — NOT FOUND.** The reference gives no length. Community reports an undocumented cap with drifting measured values (1024 / 1027 / 1280) and this error shape: `Error code: 400 - {'error': {'message': '"..." is too long - 'functions.2.description'', 'type': 'invalid_request_error'}}` — **UNVERIFIED**, https://community.openai.com/t/function-call-description-max-length/529902. Keep MCP tool descriptions concise (a few hundred characters).
- **Number of tools: NO current documented cap — NOT FOUND.** Official guidance is soft: "**Aim for fewer than 20 functions available at the start of a turn** at any one time, though this is just a soft suggestion." Observed caps (**UNVERIFIED**): `Invalid 'tools': array too long. Expected an array with maximum length 128, but got an array with length 131 instead.` (https://github.com/NousResearch/hermes-agent/issues/13037) and a legacy `'$.functions' is too long. Maximum length is 64` (https://community.openai.com/t/function-call-limit-count/287161). Treat **128** as the practical observed ceiling and 20 as the quality target; `allowed_tools` (Responses MCP) or `tool_search`/`defer_loading` for large surfaces.

---

## 3. Known incompatibilities — exact failures and fixes

### 3.1 `format: "uri"` → hard 400 (VERIFIED, community PR with quoted error)
```
ApiProviderError: Invalid request to Responses API - Invalid schema for function
'mcp--fetch--fetch': In context=('properties', 'url'), 'uri' is not a valid format.
```
Root cause stated in the PR: OpenAI strict mode supports only `date-time`, `time`, `date`, `duration`, `email`, `hostname`, `ipv4`, `ipv6`, `uuid`; `uri`, `uri-reference`, `iri` etc. are not supported.
**Fix:** strip/omit unsupported `format` values recursively.
Source: https://github.com/RooCodeInc/Roo-Code/pull/10198

### 3.2 Missing `additionalProperties: false` → hard 400 (VERIFIED, official OpenAI repo; corroborated)
```
Error code: 400 - {'error': {'message': "Invalid schema for function 'process_user':
In context=(), 'additionalProperties' is required to be supplied and to be false.",
'type': 'invalid_request_error', 'param': 'tools[0].parameters',
'code': 'invalid_function_parameters'}}
```
Sources: https://github.com/openai/openai-agents-python/issues/992 and https://github.com/openai/openai-agents-python/pull/1041 (OpenAI repo; the SDK now auto-applies `ensure_strict_json_schema`).

Same error for an actual MCP tool, with the author's claim that this applies "even for non-strict tools (MCP tools)":
```
Invalid schema for function 'mcp--github--get_me': In context=(), 'additionalProperties' is required to be supplied and to be false.
```
Source (**UNVERIFIED**): https://github.com/RooCodeInc/Roo-Code/pull/10472 — this PR **adds** `additionalProperties: false` defensively while keeping `strict: false`, and notes "modern MCP servers (GitHub, Linear, Context7) already include `additionalProperties: false`."
**Fix: ADD `additionalProperties: false` to every object level, recursively (including inside `anyOf` branches). Never remove it.**

### 3.3 Object schema missing `properties` → hard 400 (VERIFIED, official OpenAI repo issue + corroboration)
```
Invalid schema for function 'say_hello': In context=(), object schema missing properties.
(param: tools[0].parameters)
```
The repro MCP schema was `{"$schema":"http://json-schema.org/draft-07/schema#","title":"EmptyObject","type":"object"}` — OpenAI complained **only** about `properties`, **not** about `$schema`.
Source: https://github.com/openai/openai-agents-python/issues/449

Same failure from real MCP servers, with exact text:
- `400 Invalid schema for function 'mnemos__knowledge_metrics': In context=(), object schema missing properties. (format)` — zero-arg handler serialized as `{"type":"object"}` because `properties` had `,omitempty`. Fix: always emit `properties` (`{}` when empty) for `type: object`, plus `additionalProperties`. https://github.com/klarlabs-studio/mcp-go/pull/78
- `400 Invalid schema for function 'list_agents_mcp_<server>': object schema missing properties` — https://github.com/kagent-dev/kagent/pull/1892
- `400 Invalid schema for function 'flux-mcp__get_flux_instance': In context=(), object schema missing properties.` — fix normalizes `{}` / `{type:"object"}` / null `inputSchema` → `{type:"object", properties:{}}`. https://github.com/openclaw/openclaw/pull/77230
**Fix:** every object schema must carry an explicit `properties` key, even `{}`.

### 3.4 `default` → rejected on Azure (UNVERIFIED against api.openai.com; contradicted by maintainer test)
```
'default' is not permitted within a property definition
```
Reporter context: Pydantic field with a **non-null** default (enum/Decimal/int/string) inside a strict schema; the SDK's `ensure_strict_json_schema()` only stripped `default` when its value was exactly `None`.
**Critical correction:** OpenAI maintainer `seratch` tested the same schema **with and without** `"limit": {"type":"integer","default":10}` against **`api.openai.com`** with `gpt-5.6-sol` and `strict: True` and **could not reproduce a failure caused by `default`** — "Both requests co[mpleted]". The reporter confirmed they were hitting it through **`AsyncAzureOpenAI`** (Azure deployment), not the OpenAI direct API.
Source: https://github.com/openai/openai-agents-python/issues/4390
**Fix / guidance:** `default` is not a supported Structured Outputs keyword. On `api.openai.com` it appears tolerated (effectively ignored) — verified by the maintainer's probe. On **Azure OpenAI it is rejected**. Strip `default` from all properties for portability.

### 3.5 Nullable enum → invalid `anyOf` branch (UNVERIFIED, community issue with exact error)
```
Error: 400 Invalid schema for function 'mcp__sentry_search_docs':
context=('properties', 'guide', 'anyof', '1'), enum value javascript does not
validate against {'type': 'null'}.
```
Trigger: an MCP server (Sentry `search_docs`) exposing a nullable enum — `anyOf: [{"type":"string","enum":["javascript","python"]}, {"type":"null"}]` with `default: null`. The client's normalizer rewrote the schema to a `type` array and then **copied the enum constraint onto the `null` branch**, producing `{"enum":["javascript","python"],"type":"null"}`, which OpenAI's server-side validator correctly rejects.
Source: https://github.com/can1357/oh-my-pi/issues/1835
**Fix:** never place `enum`/`const` on a `{"type":"null"}` branch. Use either the documented flat form `"type": ["string","null"], "enum": ["javascript","python"]`, or an `anyOf` whose null branch is exactly `{"type": "null"}` with no enum.

### 3.6 `oneOf` / `allOf` / root non-object → hard 400 (UNVERIFIED, community, exact text)
- `Invalid schema for function 'create_where_clause': In context=(), 'oneOf' is not permitted.` — fix: use `anyOf`. https://community.openai.com/t/oneof-allof-usage-has-problems-with-strict-mode/966047
- `Invalid schema for function 'notion__notion-update-page': In context=('properties', 'data'), 'allOf' is not permitted.` — fix: generate schemas without `allOf`. https://github.com/makenotion/notion-mcp-server/issues/102
- `Invalid schema for function 'map_reverse_geocode': schema must have type 'object' and not have 'oneOf'/'anyOf'/'allOf'/'enum'/'not' at the top level.` (real Baidu Maps MCP server) — fix: repackage the schema before adapting. https://github.com/langchain-ai/langchain-mcp-adapters/discussions/507
- `Invalid schema for function 'MySchema': In context=('properties','my_arg','items','anyOf','0'), 'additionalProperties' is required to be supplied and to be false.` — `additionalProperties: false` is required **inside each `anyOf` branch** too. https://github.com/langchain-ai/langchain/issues/30970
- `Invalid schema for function 'mcp_arr_stack_sonarr_update_custom_format': In context=('properties','specifications'), array schema missing items.` — every array needs `items`. https://github.com/NousResearch/hermes-agent/issues/13037

### 3.7 `additionalProperties: false` + genuinely optional properties → forced-argument pathology (UNVERIFIED)
`additionalProperties: false` combined with properties **not** in `required` is a contradictory signal: OpenAI's strict contract requires "all properties required" whenever the constraint is present, and compatible gateways enforce it by promoting **all** properties to `required` — forcing mutually exclusive optional fields on every call, then looping on client-side validation. Fix adopted: drop `additionalProperties: false` only on object levels that declare optional properties; keep it where everything is required; also drop `$schema`/`$id` metadata.
Source: https://github.com/QwenLM/qwen-code/commit/2374f69c9acb364893738fc88f15321a209af320
**Guidance for a server author:** avoid this dilemma entirely — make property sets genuinely all-required, or make the whole level nullable-as-needed. Do not mix closed objects with truly-optional (non-nullable) properties.

### 3.8 ChatGPT / Agent Builder MCP client bugs (UNVERIFIED, community forum)
Non-schema but operationally relevant reports in one thread: an auth token being wrapped in stray double quotes during `initialize` (breaking tool loading), Agent Builder not sending the `initialize` JSON-RPC so no `Mcp-Session-Id` is issued, `422/424` tool-discovery failures, and tool-count sensitivity ("I reduced the number of tools exposed… the tools loaded correctly again… as soon as I added more tools back, the error reappeared"). One reporter notes their server works fine from Cursor/n8n.
Source: https://community.openai.com/t/issue-when-try-to-use-any-of-mcp-servers-or-connectors-in-agent-builder/1361356

### 3.9 Does OpenAI require a `$schema` key? — **NOT REQUIRED, and NOT REJECTED (VERIFIED)**

- It is **not required.** Nothing in the Chat Completions or Responses reference lists `$schema` as a required field of `function.parameters` or of MCP `inputSchema`; `parameters` is described only as "a JSON Schema object."
- It is **not rejected.** OpenAI's own MCP guide example shows an MCP server's `input_schema` carrying `"$schema": "https://json-schema.org/draft/2020-12/schema"` and OpenAI re-emitting it intact in `mcp_list_tools`:
  ```json
  "input_schema": {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "type": "object",
    "properties": { "diceRollExpression": { "type": "string" } },
    "required": ["diceRollExpression"],
    "additionalProperties": false
  }
  ```
- In openai-agents-python #449 an MCP schema containing `"$schema": "http://json-schema.org/draft-07/schema#"` was rejected **only** for the missing `properties` key — not for `$schema`.
- Official OpenAI repo code lists `$schema` among allowed `$ref`-sibling keywords: https://github.com/openai/openai-agents-python/blob/main/src/agents/strict_schema.py
- **NOT FOUND:** any report of `api.openai.com` rejecting `$schema` in `function.parameters` or `inputSchema`; there is no `"$schema is not permitted"` / "Unknown parameter: `$schema`" error for OpenAI. The `$schema`-stripping PRs I found target **other** providers: Gemini (`openclaw/openclaw#567` removes `$schema`, `$id`, `$ref`, `$defs` for Google Cloud Code Assist) and OpenAI-compatible gateways (`QwenLM/qwen-code#7344` drops `$schema`/`$id` as hygiene).
- **Recommendation:** `$schema` is optional metadata. Leaving a correct `"$schema": "https://json-schema.org/draft/2020-12/schema"` in your MCP `inputSchema` is safe for OpenAI; omitting it is equally safe and marginally simpler. Do **not** strip it on OpenAI's behalf.

---

## 4. Practical compatibility guidance

### 4.1 The safe schema subset — intersection for BOTH Chat Completions `strict: true` and the Responses API MCP tool

Root:
```json
{ "type": "object",
  "properties": { ... },
  "required": [ "<every key in properties>" ],
  "additionalProperties": false }
```

Rules that are safe on both paths:
1. **Root is always `{"type":"object"}`.** Never `anyOf`/`oneOf`/`allOf`/`enum`/`not` at the root.
2. **Every object level** — including inside `anyOf` branches and `$defs` — has an explicit `properties` (use `{}` for zero-arg tools) **and** `"additionalProperties": false`.
3. **Every property is listed in `required`.** Optionality is expressed only via a nullable type.
4. **Optional/nullable property:** `"type": ["<base>", "null"]`, keep it in `required`, and keep `enum` to non-null values only. Prefer this flat form over `anyOf`.
5. **Types:** `string`, `number`, `integer`, `boolean`, `object`, `array`; plus `enum`; plus `anyOf` **nested** (never at root).
6. **Arrays:** always have `items`. `minItems`/`maxItems` are supported and safe (except on fine-tuned models).
7. **Numbers:** `minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`, `multipleOf`.
8. **Strings:** `enum`, `pattern`, and `format` restricted to `date-time`, `time`, `date`, `duration`, `email`, `hostname`, `ipv4`, `ipv6`, `uuid`. **Never `format: "uri"`.**
9. **No `default`.** Not a supported keyword; tolerated on `api.openai.com` but rejected on Azure.
10. **No `oneOf`, `allOf`, `not`, `if`/`then`/`else`, `dependentRequired`, `dependentSchemas`, `patternProperties`, `propertyNames`, `minProperties`, `maxProperties`, `unevaluatedProperties`, `uniqueItems`, `contains`, `minContains`, `maxContains`, `unevaluatedItems`. Rewrite `oneOf` → `anyOf`.
11. **`$defs`/`$ref`: allowed** (must be nested under the schema object). Inlining is still safer for schema-normalizing clients.
12. **`$schema`/`$id`:** optional, accepted by OpenAI. Harmless to include, harmless to omit.
13. **Budgets:** ≤5000 object properties, ≤10 nesting levels, ≤1000 enum values total, ≤120,000 chars total across names/enum/const, ≤64 chars per tool name.
14. **Tool count:** aim ≤20 exposed tools for accuracy; keep under ~128 per request (observed ceiling, unofficial).
15. **Results:** return `structuredContent` **and** a JSON-encoded duplication in `content[0].text`. Declare `outputSchema` for validation and for ChatGPT app review, but do not depend on an OpenAI client reading it.

### 4.2 Should union `type` arrays be avoided?

**No — do not avoid them. They are the officially documented, strict-mode-supported way to express an optional parameter.** The function-calling guide's `strict: true` example and the Structured Outputs "All fields must be `required`" example both use `"type": ["string","null"]`. No official rejection of a `type` array was found, and the one community claim that "OpenAI rejects `["string","null"]`" supplies no error text and is contradicted by the official examples. See §1 and §2.3.

What **should** be avoided:
- `enum` or `const` on a `{"type":"null"}` branch (verified real 400: `enum value javascript does not validate against {'type': 'null'}`) — this is the actual union-type breakage reported in the wild, and it originates in a client's normalizer, not in the MCP server. Design so a naive normalizer cannot produce it.
- `oneOf` — unsupported; use `anyOf`.
- Top-level unions (root must be a plain object).
- Any `$ref` sibling combination that a normalizer might mishandle; prefer inlining.

**Instead of unions**, where a discriminator is genuinely needed, use a nested `anyOf` with each branch a fully closed object (`properties` + `allOf`-free + `additionalProperties: false` + all keys `required`).

### 4.3 Swift-server-specific checklist

- Serve **Streamable HTTP** at a stable public HTTPS endpoint (`/mcp`); optionally also accept legacy **HTTP/SSE**. No direct stdio for the Responses API — bridge local stdio via Secure MCP Tunnel (`tunnel_id`) or use the Agents API stdio transport.
- Implement `initialize` (return negotiated `protocolVersion`; accept 2025-06-18 and 2025-03-26), `tools/list`, `tools/call` as JSON-RPC 2.0. Honor `Mcp-Session-Id`; accept `Accept: application/json, text/event-stream`.
- Emit `ToolAnnotations` with accurate `readOnlyHint` / `destructiveHint` / `openWorldHint` — OpenAI's `allowed_tools.read_only` and `require_approval.*.read_only` filters match on `readOnlyHint`.
- Advertise **closed** schemas: `additionalProperties: false`, explicit `properties` (even `{}`), every key in `required`, no `format: "uri"`, no `default`, no `allOf`/`oneOf`.
- Return both `structuredContent` and a JSON-encoded text mirror in `content`.
- Add a schema-lint step in Swift that walks the generated `inputSchema` and asserts the rules in §4.1 before serving `tools/list`.

---

## Appendix — exact error-string index

| Error text | Cause | Fix | Source |
|---|---|---|---|
| `In context=(), 'additionalProperties' is required to be supplied and to be false.` | object missing closed schema | add `additionalProperties: false` everywhere | openai/openai-agents-python#992, #1041 |
| `In context=(), object schema missing properties.` | object with no `properties` key | emit `properties: {}` | openai/openai-agents-python#449; mcp-go#78; kagent#1892; openclaw#77230 |
| `In context=('properties', 'url'), 'uri' is not a valid format.` | `format: "uri"` | strip unsupported `format` values | Roo-Code#10198 |
| `In context=(), 'oneOf' is not permitted.` | `oneOf` | use `anyOf` | community.openai.com/t/…/966047 |
| `In context=('properties', 'data'), 'allOf' is not permitted.` | `allOf` | remove `allOf` | notion-mcp-server#102 |
| `schema must have type 'object' and not have 'oneOf'/'anyOf'/'allOf'/'enum'/'not' at the top level.` | non-object/union root | wrap in an object root | langchain-mcp-adapters#507 |
| `In context=('properties','specifications'), array schema missing items.` | array without `items` | add `items` | hermes-agent#13037 |
| `enum value javascript does not validate against {'type': 'null'}` | enum copied onto null branch | no `enum` on null branches | oh-my-pi#1835 |
| `'default' is not permitted within a property definition` | `default` (Azure) | strip `default` | openai-agents-python#4390 |
| `Invalid 'tools': array too long. Expected an array with maximum length 128` | >128 tools | filter via `allowed_tools` | hermes-agent#13037 (**UNVERIFIED**) |
| `Invalid schema for function … In context=('properties','my_arg','items','anyOf','0'), 'additionalProperties' is required…` | anyOf branch left open | close every branch | langchain#30970 |
